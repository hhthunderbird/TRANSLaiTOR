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
- On: invokes `ollama run --verbose --nowordwrap $Model`. Captures stderr
  to a temp file (instead of discarding via `2>$null`), reads it after the
  process exits, deletes the temp file, and returns
  `[pscustomobject]@{ Text=<stdout-string>; Stats=<hashtable-or-null> }`.

Stderr is parsed via the new helper below. Parse failure returns
`Stats=$null`; the call itself is never failed by stat parsing.

### `Parse-OllamaVerboseStats` (cprompt.psm1, exported)

Pure function. Input: stderr text. Output: hashtable or `$null`.

Recognized fields (regex, case-insensitive, tolerant of formatting drift):

```
prompt eval count:    <int>          → promptEvalCount
prompt eval duration: <ms|s|m>       → promptEvalDurationMs
eval count:           <int>          → evalCount
eval duration:        <ms|s|m>       → evalDurationMs
eval rate:            <float> tokens/s → evalRate
```

Returns hashtable containing only the fields that matched. If none match,
returns `$null`. Duration parsing must handle `12.345s`, `200ms`, `1m30s`.

### c.ps1 metrics wiring

Two changes, both isolated to the existing metrics block (lines ~264-287):

1. Refiner and compiler calls pass `-CaptureStats`; the returned `.Text`
   replaces the old string assignment, and `.Stats` is held in local vars
   `$refinerStats` and `$compilerStats`.
2. The metrics entry gains two opt-in keys (added only when the value is
   non-null):
   - `compilerEval`: hashtable from `Parse-OllamaVerboseStats`.
   - `refinerEval`: same shape, only present when refiner actually ran
     (not on `-NoRefine`, not on refiner passthrough).

Cache-hit runs do not invoke ollama, so neither field is populated. This
matches the existing convention (no `compilerMs` either on cache hits).

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
  "mode": "compiled", "inputChars": 42, "refinedChars": 38, "xmlChars": 220,
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

- `Parse-OllamaVerboseStats`:
  - Full canonical stderr block → all five fields populated, durations in
    ms.
  - Partial stderr (only `eval count` + `eval rate`) → only those keys
    present.
  - Empty / unrelated stderr → `$null`.
  - Duration unit parsing: `12.345s` → 12345, `200ms` → 200, `1m30s` →
    90000.
- `Get-MetricsSummary` with entries containing `compilerEval`:
  - p50 / p95 of evalRate match hand-computed values.
  - Median evalCount matches.
  - Empty / missing-field cases yield 0 (or absent key), no exceptions.

### Integration (Tests/c.Integration.Tests.ps1)

- New env `CPROMPT_TEST_EVAL_STATS` recognized by ollama-impl.ps1: when
  set to a JSON object keyed by model, the stub also writes a synthetic
  verbose block to stderr (matching the canonical ollama format) before
  exiting.
- New It block "compiler eval stats land in metrics entry": runs c.ps1,
  reads last `metrics.jsonl` entry, asserts `compilerEval.evalRate` is a
  number > 0 and `compilerEval.evalCount` matches the fixture.

No new fixtures required beyond extending the existing JSON files with an
optional `verbose` key per model.

## Risks

- **Ollama version drift.** `--verbose` field names and unit suffixes
  could change across releases. Mitigation: regex tolerant, parse failure
  is silent, no caller depends on stats being present.
- **Stderr capture races.** Temp file is read after `Out-String` consumes
  stdout, which finalizes the pipeline. No race expected on Windows.
- **Performance.** `--verbose` adds no measurable overhead; stderr is
  small (~150 bytes).

## Out of scope (deferred follow-ups)

- Claude API token usage on `-Send` runs.
- Cold-start flag (first ollama call vs subsequent).
- `cstats -Since <date>` / `cstats -By <mode>` groupings.
- Refiner stats in summary output.
