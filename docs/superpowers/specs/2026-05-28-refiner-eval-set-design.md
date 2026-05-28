# Refiner eval set expansion — design spec

**Date:** 2026-05-28
**Status:** Approved (pending user spec review)
**Origin:** Session 2026-05-28, follow-up to PRs #45–49. Triggered by refiner probe (PR #48) showing the 8-case `Tests/fixtures/refiner-corpus.json` does not cover the failure patterns observed on real production inputs from `~/.cprompt/history.jsonl`.

## Problem

`Tests/Refiner.Quality.Tests.ps1` validates `prompt-refiner` on 6 live cases (3 `passthrough`, 3 `questions`) plus 2 zero-signal pre-gate rejects. The probe in PR #48 exposed three real-world failure classes that the bench cannot catch:

1. **CamelCase identifiers** misclassified as `questions` (e.g. `ExamMembership`, `ToggleEventButton`, `InteractiveExamManager`).
2. **In-rule keywords failing to fire** (e.g. `quero implementar cache LRU em Go` chose `questions` despite `go` being in `DECISION RULE`).
3. **Mid-conversation replies with concrete topics** always asked (e.g. `vamos continuar com o visual companion`).

The fixes shipped in PR #48 are not protected by the bench. A future Modelfile edit could silently undo them and the test would still pass.

## Goal

Expand the corpus from 8 to ~28 cases, sourced from real history, with a schema that tolerates genuinely borderline inputs. Ship a baseline-regen utility so future corpus updates are reproducible.

## Non-goals

- Auto-curating the corpus from `history.jsonl` on every run (YAGNI; manual curation is fine for the ~655-entry corpus).
- Cross-version model comparison framework (deferred).
- Per-category grouped bench reports (Approach 3 from brainstorm; YAGNI now).
- Anonymising identifiers — `eval-sample.json` (PR #42) already commits the same identifiers; no new exposure.

## Architecture

```
refiner-corpus.json  ─►  Invoke-RefinerBaseline.ps1  ─►  baseline.json
                     ╲
                      ╲►  Refiner.Quality.Tests.ps1  ─►  statistical invariants
                                                        + regression vs baseline
```

Three components touched, one new:

| File | Change |
|------|--------|
| `Tests/fixtures/refiner-corpus.json` | Expand from 8 to ~28 cases. Bump `version: 1 → 2`. Add optional `acceptableModes` field. |
| `cprompt.psm1` — `Get-RefinerRegressions` | Read optional `acceptableModes`; sum baseline hits and fresh hits across all acceptable modes. Back-compat: when field absent, behaviour is identical to today. |
| `Tests/Refiner.Quality.Tests.ps1` | One-line update to the "hits expected mode" `It` block: use `acceptableModes` when present. |
| `Tests/Invoke-RefinerBaseline.ps1` | **NEW.** Single-source-of-truth utility to regenerate `bench-results/baseline.json` from the corpus. |
| `bench-results/baseline.json` | Regenerated with N=20 trials/case after corpus expansion. |
| `Tests/cprompt.Tests.ps1` | New `Describe 'refiner-corpus.json schema'` (fixture validation) and two new `It` blocks in existing `Describe 'Get-RefinerRegressions'` exercising the multi-acceptable path. |

## Corpus content

**Carry-over (8 existing cases):** kept verbatim, no `acceptableModes` field (back-compat).

**From `Tests/eval-sample.json`, deduped (~16 new cases):**

| Tag bucket | Count | Mode | Examples |
|------------|------:|------|----------|
| CamelCase identifier (passthrough) | 5 | `passthrough` | `ExamMembership Exam precisa ser flag`, `ToggleEventButton não disparando`, `InteractiveExamManager carregando prefabs`, `AutoHandSimulatorUIInteraction raycast`, `ExamProfile Visibility Rules` |
| Lang keyword (passthrough) | 1 | `passthrough` | `quero implementar cache LRU em Go` |
| Error-log marker (passthrough) | 2 | `passthrough` | `NullReferenceException` + `at Assets/...cs:137`, `error CS1061 file.cs(193,51)` |
| Mid-conv reply w/ topic (borderline) | 3 | `passthrough` + `acceptableModes: [passthrough, questions]` | `vamos continuar com o visual companion`, `agora reavalie os Injects`, `Explicação aceita. E um dropdown enum-flag?` |
| File-path commit list (passthrough) | 1 | `passthrough` | `RASCALSkinnedMeshCollider.cs, RascalExtensions.cs ... faça o commit` |
| Git operation w/ stack (passthrough) | 1 | `passthrough` | `Limpe os debug logs desnecessários e liste os commits` |
| Genuinely vague (questions) | 3 | `questions` | `ideia vaga`, `A, depois follow-ups`, `comece a investigação` (last w/ `acceptableModes: [questions, passthrough]`) |

**Synthetic edge cases (4 new):**

| Tag | Mode | Rationale |
|-----|------|-----------|
| `english + long + identifier` | `passthrough` | Existing corpus has only one English case (`vague-worker`). |
| `long-input + stack-trace` (>500 chars) | `passthrough` | Exercises `num_predict 120` / `num_ctx 1024` truncation behaviour. |
| `pt-en-mix` | `passthrough` | e.g. `bug no controller, vai dar TypeError no JSON.parse`. |
| `bare-identifier` (single CamelCase, no verb) | `passthrough` + `acceptableModes: [passthrough, questions]` | Edge case: identifier alone is barely-A. |

**Total target:** ~28 cases (6 existing live + 16 deduped + 4 synthetic + 2 existing rejected). Final count may shift ±2 during implementation as fixture is reviewed.

**Tags added (convention, not enum-enforced):** `camelcase`, `mid-conv`, `error-log`, `file-path`, `english`, `pt-en-mix`, `long-input`, `borderline`. Documented in fixture top comment.

## Schema change

Bump `refiner-corpus.json` `version: 1 → 2`. Add one optional field per case:

```jsonc
{
  "id": "borderline-mid-conv-companion",
  "input": "vamos continuar com o visual companion",
  "expectedMode": "passthrough",                       // primary; what we'd ideally see
  "acceptableModes": ["passthrough", "questions"],     // OPTIONAL; either counts as a hit
  "tags": ["camelcase", "mid-conv", "borderline"]
}
```

**Semantics:**
- `expectedMode` is **required** (primary mode; what we want).
- `acceptableModes` is **optional**. When present, it MUST be an array containing at least `expectedMode` plus any other modes that count as a successful classification.
- When absent, the bench treats `acceptableModes` as `[expectedMode]` (current behaviour).
- Valid mode values: `passthrough`, `questions`. (`rejected` cases are not subject to acceptableModes — they short-circuit the live test.)

**Top-of-fixture `notes` field** updated to describe `acceptableModes` and the tag convention.

## Bench code change (`Refiner.Quality.Tests.ps1`)

One `It` block in `Describe 'Refiner statistical invariants'`:

```ps1
It "hits expected mode (<_.expectedMode>) in >=60% of trials" -Skip:($_.expectedMode -notin @('passthrough','questions')) {
    $accept = if ($_.PSObject.Properties['acceptableModes'] -and $_.acceptableModes) {
        @($_.acceptableModes)
    } else {
        @($_.expectedMode)
    }
    $hit  = @($script:Dist | Where-Object { $_.Mode -in $accept }).Count
    $rate = $hit / $script:Trials
    Write-Host ("    [{0}] {1}={2}/{3} ({4:P0})" -f $script:CaseId, ($accept -join '|'), $hit, $script:Trials, $rate)
    ($rate -ge 0.6) | Should -Be $true
}
```

## `Get-RefinerRegressions` change (`cprompt.psm1`)

Update hit-counting in both baseline and fresh-distribution paths to sum across `acceptableModes`. When the field is absent on a baseline case, behaviour is identical to today.

Pseudocode of the diff:

```ps1
$expected = [string]$case.expectedMode
$acceptable = if ($case.PSObject.Properties['acceptableModes'] -and $case.acceptableModes) {
    @($case.acceptableModes | ForEach-Object { [string]$_ })
} else {
    @($expected)
}

# Sum baseline hits across all acceptable modes
$baseHits = 0
foreach ($m in $acceptable) {
    $prop = $case.modeCounts.PSObject.Properties[$m]
    if ($prop) { $baseHits += [int]$prop.Value }
}
$baseRate = $baseHits / $baseTrials

# Fresh hits: any acceptable mode counts
$freshHits = @($fresh | Where-Object { [string]$_.Mode -in $acceptable }).Count
```

## `Tests/Invoke-RefinerBaseline.ps1` — new utility

**Signature:**

```ps1
[CmdletBinding()]
param(
    [int]$Trials = 20,
    [string]$RefinerModel = 'prompt-refiner',
    [string]$CorpusPath  = (Join-Path $PSScriptRoot 'fixtures/refiner-corpus.json'),
    [string]$OutputPath  = (Join-Path (Split-Path $PSScriptRoot) 'bench-results/baseline.json'),
    [switch]$Force
)
```

**Behaviour:**

1. Import `cprompt.psm1`. Verify `ollama` on PATH and `prompt-refiner` model present (fail fast with clear message).
2. Read corpus; filter out `rejected` cases (they do not go to baseline — pre-gate handles them).
3. For each remaining case, run `Invoke-OllamaModel -Text $case.input -Model $RefinerModel -CaptureStats` `$Trials` times. Parse with `Get-RefinerOutput`. Record per-trial `mode`, `qCount`, and `totalDurationMs` from the stats block.
4. Aggregate per case: `modeCounts{}`, `qCountCounts{}`, latency `p50`/`p95`, full `samples[]`.
5. Emit JSON matching the existing `baseline.json` schema: top-level `startedAt`, `endedAt`, `durationSec`, `refinerModel`, `trialsPerCase`, `corpusVersion`, `cases[]`.
6. **Overwrite protection:** if `OutputPath` exists, refuse without `-Force`. Print a clear hint.
7. **Progress output:** `[i/N] case.id ...` per case (matches the style of `Tests/Invoke-EvalRerun.ps1`).

**Cost:** 28 live cases × 20 trials × ~300ms = ~170s one-shot. Acceptable.

**Not handled:** model non-determinism between runs. The `temperature 0.05` setting and `DropThreshold 0.40` bench tolerance absorb the variance. Future: could run baseline 3× and average — YAGNI.

## Tests

**New `Describe` blocks in `Tests/cprompt.Tests.ps1`:**

1. `refiner-corpus.json schema` — fixture validation:
   - Every case has a non-empty `id`. IDs are unique across the corpus.
   - Every case has a non-empty `input`.
   - `expectedMode ∈ {passthrough, questions, rejected}`.
   - When `acceptableModes` is present, it is an array, every element is in `{passthrough, questions}`, and the array contains `expectedMode`.
2. `Get-RefinerRegressions multi-acceptable mode` — two new `It` blocks:
   - Baseline case with `acceptableModes: [passthrough, questions]`; fresh distribution lands in the alternative acceptable mode → returns zero failures.
   - Same baseline case; fresh distribution lands fully in `invalid` (outside all acceptable modes) → returns one failure.

**New `Describe` block in `Tests/Refiner.Quality.Tests.ps1`:**

3. `Invoke-RefinerBaseline smoke` (`-Tag 'Live'`):
   - Run `Invoke-RefinerBaseline.ps1 -Trials 2 -OutputPath $TestDrive/baseline-smoke.json` against a minimal 1-case corpus.
   - Validate the output JSON has `trialsPerCase: 2`, `cases.Count: 1`, the case has `modeCounts` with all three keys (`passthrough`, `questions`, `invalid`), and `samples.Count: 2`.

**Manual pre-PR smoke:** run `./Tests/Invoke-RefinerBaseline.ps1` on the user's machine, eyeball the per-case mode-hit rates against expectations, then commit.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `acceptableModes` is too permissive — borderline cases always pass, test loses signal | Medium | Test loses regression-detection power | Limit `acceptableModes` to 4-5 genuinely borderline cases; document `borderline` tag explicitly; reviewer-flag any case where both modes feel valid |
| Single-run baseline snapshot freezes an atypical distribution | High | Future bench runs flag false-positive regressions | Use `Trials=20` for baseline (vs `10` for bench); the `DropThreshold=0.40` is wide enough to absorb normal variance |
| 28 cases × 10 trials inflates bench time | Confirmed | Live bench grows from ~105s to ~250s | Already `-Tag 'Live'`; CI runs remain opt-in |
| `Get-RefinerRegressions` back-compat break for existing 8 cases | Low | Existing cases fail regression after the change | Fallback `acceptable = @(expectedMode)` when field absent — covered by the existing 8 cases' regression test |
| Identifier leak (privacy) | Already accepted | None new | Same exposure as `eval-sample.json` (PR #42) |
| Corpus drift: history.jsonl evolves, fixture becomes unrepresentative | Low | Bench protects against patterns from May 2026 only | Fixture top-comment documents "regenerate when real-world patterns diverge"; no auto-regen (YAGNI) |
| `baseline.json` has `latencyMsP50/P95` populated today — implementation must replicate; if `Invoke-OllamaModel -CaptureStats` is not how the original baseline got latency, the new utility schema diverges | Low | Schema mismatch breaks regression test | Verified during implementation: read the existing `baseline.json`, match the field set; `-CaptureStats` returns `totalDurationMs` — sufficient. |

## Out of scope

- Approach 3 features from the brainstorm: taxonomy enforcement, per-category grouped bench reports, longitudinal `bench-results/history/`.
- Auto-curating fixture from `history.jsonl`.
- Cross-model comparison framework (would be needed for the 3B→7B upgrade vector).

These remain on the "future vectors" list and can be picked up in their own brainstorm/spec cycle.
