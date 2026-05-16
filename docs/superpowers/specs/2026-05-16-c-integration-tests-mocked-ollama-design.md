# c.ps1 integration tests with mocked ollama — design

**Date:** 2026-05-16
**Status:** Approved
**Tracking:** deferred follow-up #5 in `project_resume_state.md` memory

## Problem

`Tests/c.Tests.ps1` (167 lines) covers c.ps1 only along no-ollama paths (`-Help`, no prompt, oversize input, `-Last`, banner assertions). The flows that exercise the production happy path — refiner → compiler, cache hit/miss, Q&A loop, `-Send` with/without `claude`, frictionless fallback, `-NoRefine` direct-to-compiler — are untested end-to-end. Bugs that span the pipeline boundaries (e.g., PR #20's dead `-Send` guard) escape unit coverage.

The blocker is `Invoke-OllamaModel` in `cprompt.psm1:88-98` calling `ollama run` directly. Without a way to substitute that call, integration tests need a real `ollama` binary plus loaded models — too slow and non-deterministic for CI.

## Goal

Add ~10 integration tests that exercise c.ps1 end-to-end with a mocked `ollama` binary. No dependency on real ollama, no host-state pollution, no production code coupling to test infrastructure beyond a single environment-variable hook.

## Non-goals

- Replacing the existing subprocess-based unit tests in `c.Tests.ps1`.
- Refactoring c.ps1 into a module function (option C from brainstorming).
- Recording real ollama outputs and replaying them (`record-and-replay`).
- Testing the metrics or history modules — both have dedicated unit tests in `cprompt.Tests.ps1`.
- Asserting clipboard contents (would pollute the host clipboard).

## Approach

**PATH-shim with env-var fixture lookup.** A `.cmd` shim named `ollama.cmd` (and `claude.cmd` for `-Send` tests) sits at the front of the subprocess PATH and dispatches to a PowerShell stub. The stub reads a JSON fixture file pointed to by `$env:CPROMPT_TEST_FIXTURE`, parses the model name from `$args`, and writes the fixture's payload for that model to stdout. State (cache, history, metrics) is redirected away from `$env:USERPROFILE` via a new `$env:CPROMPT_STATE_ROOT` hook in c.ps1.

Rejected alternatives:
- **Script-scope override in `Invoke-OllamaModel`** — requires injecting a test concern (`$script:OllamaInvoker`) into production code. Marginal speed gain; loses coverage of the actual binary lookup path.
- **Refactor c.ps1 to module function** — large structural change; deferred per memory's deferred-follow-up #5 wording ("test-only hook OR refactor").

## Architecture

### File layout

```
Tests/integration/
├── ollama.cmd                 # @powershell -NoProfile -File "%~dp0ollama-impl.ps1" %*
├── ollama-impl.ps1                 # ~25 lines: drain stdin, parse model, look up fixture, write raw
├── claude.cmd                 # @powershell -NoProfile -File "%~dp0claude-impl.ps1" %*
├── claude-impl.ps1                 # echo "OK"; append invocation; exit 0
├── fixtures/
│   ├── refiner-passthrough.json
│   ├── refiner-questions.json
│   ├── refiner-fail-then-compiler.json
│   ├── compiler-valid-xml.json
│   └── compiler-fallback-nonxml.json
└── _helpers.ps1                    # Invoke-CIntegration: build env, launch subprocess, capture stdout/exit

Tests/c.Integration.Tests.ps1       # ~10-12 It blocks, Pester 5
```

### Production-code change (1 line)

In `c.ps1`, replace the current line `$script:StateRoot = Join-Path $env:USERPROFILE '.cprompt'` with:

```powershell
$script:StateRoot = if ($env:CPROMPT_STATE_ROOT) { $env:CPROMPT_STATE_ROOT } else { Join-Path $env:USERPROFILE '.cprompt' }
```

Zero behavioural change in production (the env var is unset). Tests set the env var to a `$TestDrive`-rooted path. This is the only production change — everything else lives under `Tests/integration/`.

### Stub-ollama contract

**Invocation surface:** `ollama run [--nowordwrap] <model-name>` with prompt text on stdin.

**Stub responsibilities:**
1. Drain stdin to EOF (`[Console]::In.ReadToEnd() | Out-Null`) so the parent's pipe writer doesn't block.
2. Parse the last non-flag, non-keyword arg in `$args` as the model name (skip `run`, `--nowordwrap`, future `--<flag>` tokens).
3. Append the model name to `$env:CPROMPT_TEST_INVOCATIONS` (a file path) if set, so tests can count calls.
4. Read `$env:CPROMPT_TEST_FIXTURE` (JSON file), look up the model key, write its string value to stdout via `[Console]::Out.Write()` (raw — no extra newline, no BOM).
5. Exit 0 on success, exit 1 with a stderr line `stub: model '<x>' not in fixture` on miss.

**Stub-claude contract:** identical pattern; reads stdin (which carries the XML), appends a single `claude` line to `$env:CPROMPT_TEST_INVOCATIONS`, prints `OK` to stdout, exit 0.

### Fixture format

One JSON object per file, keyed by model name:

```json
{
  "prompt-refiner": "<refined>passthrough</refined>",
  "prompt-opt": "<task>...</task>\n<context>...</context>\n<constraints>...</constraints>"
}
```

The fixture filename describes the scenario (`refiner-passthrough.json`, `compiler-fallback-nonxml.json`). The same fixture can be reused across multiple `It` blocks when the scenario matches.

### Test helper: `Invoke-CIntegration`

A wrapper around `Start-Process powershell -NoProfile -File c.ps1 ...` that:

1. Sets `$env:Path = "$PSScriptRoot/integration;$env:Path"` so the stubs win the lookup.
2. Sets `$env:CPROMPT_STATE_ROOT = $TestDrive/cprompt-state`.
3. Sets `$env:CPROMPT_TEST_FIXTURE` to the fixture for this case.
4. Sets `$env:CPROMPT_TEST_INVOCATIONS = $TestDrive/invocations.txt` (empty file pre-created).
5. Launches c.ps1 with the requested args + optional stdin payload (for `-Interactive` Q&A answers).
6. Returns `[pscustomobject]@{ ExitCode; StdOut; StdErr; Invocations; HistoryPath; CachePath; MetricsPath }` where the `*Path` properties point under `$TestDrive` for the test to read.

### Data flow

```
Pester It block
  → builds env (fixture, state root, invocations file)
  → Invoke-CIntegration -Args @('-NoRefine','my idea') -StdIn $null
    → Start-Process powershell.exe ... c.ps1
      → c.ps1 reads $env:CPROMPT_STATE_ROOT, mounts state under $TestDrive
      → calls Invoke-OllamaModel
        → spawns ollama.cmd from PATH → resolves ollama.cmd
        → ollama-impl.ps1 reads fixture, writes XML, increments invocation counter
      → c.ps1 parses XML, writes cache, history, metrics under $TestDrive
      → exits with code
  ← test reads $TestDrive/invocations.txt, history.jsonl, cache/*, exit code
  ← assertions on count, mode, content
```

## Test cases

| # | Name | Args | Fixture | StdIn | Asserts |
|---|------|------|---------|-------|---------|
| 1 | refiner passthrough → compiler valid XML | `'sistema ecs unity'` | refiner-passthrough + compiler-valid | none | exit 0, stdout contains `<task>`, history has 1 entry, cache file exists, invocations = `prompt-refiner` then `prompt-opt` |
| 2 | cache hit on second run | rerun #1 args | (same) | none | exit 0, second-run invocations file unchanged from first-run (only refiner ran; compiler served from cache). Note: refiner runs each invocation because the cache is keyed on post-refinement input — assertion is `compiler invoked twice across both runs minus 1 = 1`. See "Open question" below. |
| 3 | `-NoCache` forces compiler call | `'-NoCache','sistema ecs unity'` after #1 | compiler-valid | none | exit 0, compiler invocation count incremented |
| 4 | refiner emits questions + `-Interactive` + answered | `'-Interactive','cache'` | refiner-questions + compiler-valid | `"redis local"` | exit 0, history.input includes both raw text and answer, metricMode = `questions` |
| 5 | refiner emits questions, no `-Interactive` (default) | `'cache'` | refiner-questions + compiler-valid | none | exit 0, metricMode = `questions-skip`, compiler receives raw input verbatim |
| 6 | `-NoRefine` skips refiner | `'-NoRefine','x'` | compiler-valid only | none | exit 0, invocations = `prompt-opt` only (no refiner call), metricMode = `raw` |
| 7 | compiler emits non-XML → frictionless fallback | `'-NoRefine','x'` | compiler-fallback-nonxml | none | exit 0, stdout contains `AVISO: otimizador nao produziu XML`, no cache file written, metricMode = `fallback` |
| 8 | `-Send` without `claude` on PATH | `'-Send','-NoRefine','x'` | compiler-valid | none | exit 8, stdout contains `claude` CLI not found message |
| 9 | `-Send` with stub-claude on PATH | `'-Send','-NoRefine','x'` (with claude.cmd staged) | compiler-valid | none | exit 0, invocations contains `claude` entry |
| 10 | zero-signal pre-gate + `-Interactive` | `'-Interactive','x'` | (no models needed) | `"area X problema Y stack Z"` | exit 0, metricMode = `pregate`, compiler receives merged input |

**Open question on test #2:** the cache key is computed over `(Model, post-refinement-userInput)`. If the refiner is `passthrough`, `userInput == rawInput`, so the key is stable across runs — second-run compiler hits the cache. If the refiner mutates the input (e.g., answered Q&A in #4), keys diverge and there is no hit. Test #2 must use a passthrough scenario for the cache hit to be deterministic. Documented; no design impact.

## Error handling

- **Fixture missing entry** → stub exits 1, c.ps1 exit 4 ("falha ao executar ollama"). One test case should cover this path to lock in the error surface.
- **Subprocess hangs** → `Start-Process` with `-Wait` and a `Pester` timeout per `It`. If a stub fails to drain stdin, the parent blocks; the timeout surfaces it as a test failure rather than a hung CI.
- **Concurrent test runs** → fixtures and invocation counters are per-`$TestDrive`, which Pester scopes per run. No global state.

## Testing

The integration suite is itself a Pester 5 file. Run discipline:
- `Invoke-Pester ./Tests/c.Integration.Tests.ps1` for the suite alone.
- `Invoke-Pester ./Tests` continues to run unit + integration together.
- CI gate stays at 0 failures.

Smoke after wiring: `./Tests/integration/ollama.cmd run --nowordwrap prompt-opt < some-input.txt` with a fixture env var set should print the fixture's `prompt-opt` payload and exit 0. This confirms the shim resolves and the stub round-trips before any test references it.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| PATH ordering on the subprocess fails (real `ollama.exe` resolves first) | Prepend `Tests/integration` to `$env:Path` in `Invoke-CIntegration`, verified by a setup-time assertion that `Get-Command ollama` resolves to the stub. |
| Stub reads BOM-prefixed UTF8 fixture and emits BOM | Read fixtures with `Get-Content -Raw -Encoding UTF8` (which strips BOM in PS 5.1) and write with `[Console]::Out.Write()` (raw, no encoding wrapper). |
| `Read-Host` in c.ps1 hangs waiting for input when the test forgot to pass stdin | Always launch `Invoke-CIntegration` with `-StdIn ''` by default so the pipe is closed; only pass an explicit stdin payload for tests #4 and #10. |
| `Set-Clipboard` pollutes the host clipboard during CI | Tests do not assert on clipboard. Accepted side-effect; documented. |
| Stub arg parser breaks if ollama adds a future `--flag <value>` (value would be picked as model) | Parser is documented as "last non-flag, non-keyword arg." If ollama's CLI shape changes, update the stub. Low likelihood — production `Invoke-OllamaModel` only ever passes `run --nowordwrap <model>`. |

## Scope decomposition

Single PR. Estimated diff:
- `c.ps1` — 1 line modified
- `Tests/integration/` — 8 new files
- `Tests/c.Integration.Tests.ps1` — 1 new file, ~200 lines
- README — optional one-line note about the new suite

No follow-up PRs anticipated unless a flow surfaces a real bug that needs fixing.
