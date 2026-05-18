# Metrics v2 — Ollama eval rate

Date: 2026-05-17
Status: design approved, awaiting plan

## Problem

Per-run metrics in `~/.cprompt/metrics.jsonl` currently capture wall-clock
durations (`refinerMs`, `compilerMs`, `totalMs`) but no model-level
throughput signal. Wall-clock conflates load time, network, and generation,
which makes it impossible to tell why a slow run was slow. Ollama already
emits per-call generation stats (`eval rate`, `eval count`, `prompt eval
count`, `eval duration`) via `--verbose` to stderr; today `Invoke-OllamaModel`
discards that stream with `2>$null`.

## Goal

Capture eval stats per run, attach them to the existing metrics JSONL entry
without breaking the current schema, and surface a compact summary in
`cstats`.

## Non-goals

- HTTP API (`/api/generate`) integration. Stays on the CLI path; deferred.
- Claude API token usage on `-Send`. Separate item in Metrics v2 follow-up.
- Cold-start flag and `cstats -Since` / `-By mode`. Separate items.
- Modifying historical JSONL entries. New fields are additive.

## Architecture

### `Invoke-OllamaModel` (cprompt.psm1)

New optional `-CaptureStats` switch:

- Off (default): unchanged. Returns string. All existing callers continue
  to work without edits.
- On: invokes `ollama run --verbose --nowordwrap $Model` via
  `System.Diagnostics.Process` (NOT the PowerShell pipeline). The Process
  API captures stdout and stderr separately as raw bytes. After
  `WaitForExit()`, stdout becomes `.Text` and stderr is run through
  `Remove-AnsiEscapes` (already exported by this module — strips the
  spinner control sequences) and then `ConvertFrom-OllamaVerboseStats`.
  Returns `[pscustomobject]@{ Text=<string>; Stats=<hashtable-or-null> }`.

Rationale for `System.Diagnostics.Process` over `& ollama ... 2>$file`:
PS 5.1 wraps native-command stderr as `NativeCommandError` records and
writes that mangled form to the file, mixing PS error headers into the
captured bytes. Verified on Ollama 0.24.0: `2>$file` produces output like
`ollama.exe : [?2026h...total duration: 4.0391184s ... At line:1 char:146
+ ... | & ollama run --verbose ...`. The Process API bypasses the PS
stream wrapping entirely.

Parse failure returns `Stats=$null`; the call itself is never failed by
stat parsing.

### `ConvertFrom-OllamaVerboseStats` (cprompt.psm1, exported)

Pure function. Input: stderr text (already ANSI-stripped). Output:
hashtable or `$null`. Verb-Noun naming follows module convention
(`Get-CachedXml`, `Get-RefinerOutput`, `Resolve-CompilerFallback`).

Recognized fields (regex, case-insensitive, tolerant of `token(s)` and
whitespace drift):

```
prompt eval count:    <int> token(s)?       → promptEvalCount
prompt eval duration: <float>(ms|s)         → promptEvalDurationMs
eval count:           <int> token(s)?       → evalCount
eval duration:        <float>(ms|s)         → evalDurationMs
eval rate:            <float> tokens/s      → evalRate
```

Duration unit handling: `ms` → as-is rounded to int; `s` → multiply by
1000, round to int. Ollama 0.24.0 emits only `ms` and `s` (verified
sample: `40.8138ms`, `4.0391184s`). No minute support.

Returns hashtable containing only the fields that matched. If none match,
returns `$null`.

### c.ps1 metrics wiring

Two changes, both isolated to the existing metrics block (lines ~264-287):

1. Refiner and compiler calls pass `-CaptureStats`; the returned `.Text`
   replaces the old string assignment, and `.Stats` is held in local vars
   `$refinerStats` and `$compilerStats`.
2. The metrics entry gains two opt-in keys (added only when the value is
   non-null):
   - `compilerEval`: hashtable from `ConvertFrom-OllamaVerboseStats`.
   - `refinerEval`: same shape. Present whenever `Invoke-OllamaModel` was
     actually called for the refiner AND parse returned non-null. This
     covers `mode=passthrough`, `mode=questions`, `mode=questions-skip`,
     and even `mode=skip` (when refiner ran but its output was garbage)
     — refiner ran the model in all of those cases, so eval stats exist.
     Refiner stats are absent only when refiner was bypassed entirely
     (`-NoRefine`, no ollama on PATH at refiner stage, or
     `Invoke-OllamaModel` threw).

Cache-hit runs do not invoke the compiler, so `compilerEval` is absent;
the refiner may still have run, so `refinerEval` may still be present.
This matches the existing convention (`compilerMs` is also absent on
cache hits while `refinerMs` may have a value).

### `cstats` surface (cstats.ps1 + Get-MetricsSummary)

`Get-MetricsSummary` gains:

- `CompilerEvalRateP50`, `CompilerEvalRateP95` — over entries with
  `compilerEval.evalRate` present.
- `CompilerEvalCountMedian` — over entries with `compilerEval.evalCount`
  present.

`cstats.ps1` adds:

```
Compiler eval/s p50: 8.4
Compiler eval/s p95: 5.2
Compiler tokens out (median): 142
```

Lines are emitted only when at least one entry has compiler eval data
(graceful for old metrics files).

Refiner stats stay in the JSONL only — useful for debugging individual
runs but not summary-worthy.

## Data shape (additions only)

```jsonl
{
  "ts": "...", "model": "prompt-opt", "refinerModel": "prompt-refiner",
  "mode": "passthrough", "inputChars": 42, "refinedChars": 38, "xmlChars": 220,
  "refinerMs": 350, "compilerMs": 8200, "totalMs": 8600, "cacheHit": false,
  "flags": { "Raw": false, "NoRefine": false, "Send": false },
  "compilerEval": {
    "promptEvalCount": 512, "promptEvalDurationMs": 180,
    "evalCount": 144, "evalDurationMs": 7900, "evalRate": 18.2
  },
  "refinerEval": {
    "promptEvalCount": 90, "evalCount": 18,
    "evalDurationMs": 320, "evalRate": 56.3
  }
}
```

Old entries without these fields stay valid: `Read-MetricsFile` already
tolerates schema drift via `ConvertFrom-Json`; `Get-MetricsSummary`
percentile/median computations skip entries that lack the field.

## Tests

### Unit (Tests/cprompt.Tests.ps1)

- `ConvertFrom-OllamaVerboseStats`:
  - Full canonical stderr block (with `token(s)` suffix, mixed `ms`/`s`)
    → all five fields populated, durations in ms.
  - Partial stderr (only `eval count` + `eval rate`) → only those keys
    present.
  - ANSI-polluted stderr after `Remove-AnsiEscapes` pre-clean → parses.
  - Empty / unrelated stderr → `$null`.
  - Duration unit parsing: `12.345s` → 12345, `200ms` → 200,
    `40.8138ms` → 41.
- `Get-MetricsSummary` with entries containing `compilerEval`:
  - p50 / p95 of evalRate match hand-computed values.
  - Median evalCount matches.
  - Empty / missing-field cases yield 0 (or absent key), no exceptions.

### Integration (Tests/c.Integration.Tests.ps1)

- The existing fixture JSON files (`Tests/integration/fixtures/*.json`)
  gain an optional `verbose` key per model entry, e.g.:

  ```json
  {
    "prompt-opt": "<task>...</task>...",
    "prompt-opt.verbose": "prompt eval count: 50 token(s)\nprompt eval duration: 100ms\neval count: 120 token(s)\neval duration: 6.0s\neval rate: 20.0 tokens/s\n"
  }
  ```

  ollama-impl.ps1 looks up `<model>.verbose` alongside `<model>` and, if
  present, writes the verbose text to stderr before exiting. Single
  mechanism — no new env var, no second source of truth.

- New It block "compiler eval stats land in metrics entry": runs c.ps1
  with a fixture containing `prompt-opt.verbose`, reads last
  `metrics.jsonl` entry, asserts `compilerEval.evalRate` ≈ 20.0,
  `compilerEval.evalCount` == 120, durations in ms.
- New It block "refiner eval stats land when refiner runs in
  passthrough mode": fixture with both `prompt-refiner.verbose` and
  `prompt-opt.verbose`, mode=passthrough; both `refinerEval` and
  `compilerEval` present.
- New It block "no eval keys on cache hit": warm cache run, neither
  `compilerEval` nor `refinerEval` present.

## Risks

- **Ollama version drift.** `--verbose` field names and unit suffixes
  could change across releases. Mitigation: regex tolerant, parse failure
  is silent, no caller depends on stats being present. Verified format
  on 0.24.0; older versions may lack one or more fields, partial parse
  is acceptable.
- **Stderr capture timing.** `System.Diagnostics.Process.WaitForExit()`
  guarantees the OS has flushed stderr before we read the captured
  `StandardError` stream. No race.
- **Spinner ANSI escapes.** `ollama run` writes a spinner control
  sequence to stderr before printing stats. Mitigated by running
  `Remove-AnsiEscapes` over the captured stderr before regex parsing.
- **Performance.** `--verbose` adds no measurable overhead; stderr is
  small (~200 bytes after ANSI strip).
- **Backward compatibility.** Existing callers of `Invoke-OllamaModel`
  (no `-CaptureStats`) get the same string return as before, same stderr
  redirect path, same exit-code behavior.

## Out of scope (deferred follow-ups)

- Claude API token usage on `-Send` runs.
- Cold-start flag (first ollama call vs subsequent).
- `cstats -Since <date>` / `cstats -By <mode>` groupings.
- Refiner stats in summary output.
