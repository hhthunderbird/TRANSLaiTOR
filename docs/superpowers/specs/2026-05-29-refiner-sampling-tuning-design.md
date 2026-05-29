# Refiner sampling tuning — design

**Date:** 2026-05-29
**Branch:** `chore/refiner-sampling-tuning`
**Status:** approved, pre-implementation

## Problem

`prompt-refiner` (llama3.2:3b) is non-deterministic on borderline inputs. Two corpus
cases flip between `passthrough` and `questions` run-to-run despite `temperature 0.05`:

- `camelcase-exam-profile-rules`
- `keyword-go-cache-lru-short` — input `quero implementar cache LRU em Go`, which is a
  **literal passthrough few-shot** in `Modelfile.refiner` (line 78). Even verbatim
  training inputs oscillate.

The PR #50 eval-expansion work absorbed this with `acceptableModes` (both modes admitted
for these cases), but that masks the instability rather than fixing it. Temperature is
already near-greedy; the width comes from `top_k 20` / `top_p 0.7` keeping a wide
candidate pool at each token.

## Hypothesis

Tightening the nucleus — `top_k 20→5`, `top_p 0.7→0.5` — collapses the candidate pool so
the dominant mode wins consistently, reducing bimodality without hurting the cases that
already route correctly.

## Goal & success criterion (Pareto / net-gain)

Accept a variant **only if**:

1. Both bimodal cases improve — max-mode-share rises toward 1.0 (more deterministic), AND
2. **No** other live case regresses below its passing threshold (expected-mode hit stays
   ≥ baseline; a case that was 10/10 passthrough must stay 10/10 passthrough).

If no variant is Pareto → **revert, zero Modelfile change**, record the finding in the
spec + memory. A non-improvement is a valid, documented outcome.

### Metric

Per case, over N trials:
- **max-mode-share** = max(passthrough, questions, invalid) / N. 1.0 = fully deterministic.
- **expected-hit** = trials landing in the case's acceptable mode set / N (existing bench
  semantics).

Bimodal improvement = max-mode-share climbs (e.g. 0.5→1.0). Regression = any case's
expected-hit drops past the `Refiner.Quality` threshold (passthrough/questions ≥ 0.6,
valid-XML ≥ 0.8).

## Experimental design

### Phase A — exploration (N=10, baseline untouched)

Build **candidate models** without overwriting the live `prompt-refiner`:

| Variant | top_k | top_p | model tag |
|---------|-------|-------|-----------|
| current (control) | 20 | 0.7 | `prompt-refiner` (existing) |
| K5  | **5**  | 0.7 | `prompt-refiner-k5` |
| P5  | 20 | **0.5** | `prompt-refiner-p5` |
| K5P5 | **5** | **0.5** | `prompt-refiner-k5p5` |

- Each candidate = copy of `Modelfile.refiner` with only the two PARAMETER lines changed,
  written to a temp Modelfile, `ollama create prompt-refiner-<tag> -f <temp>`.
- `Tools/refiner-bench.ps1 -RefinerModel prompt-refiner-<tag> -Trials 10` → writes
  `bench-results/bench-<timestamp>.json`. **Never touches `baseline.json`.**
- Control row read from existing `baseline.json` (N=20) for reference; optionally re-bench
  current at N=10 for apples-to-apples.
- Isolating each param shows which one carries the effect — avoids shipping a
  two-variable change without knowing which mattered.

**Analysis:** compare max-mode-share for the 2 bimodal cases and scan all 26 live cases
for regressions. Pick the Pareto winner (prefer the single-param variant if it matches
the double — smaller change).

### Phase B — confirmation (only if a Pareto winner exists)

1. Apply winning params to `Modelfile.refiner`.
2. Rebuild the live model: `ollama create prompt-refiner -f Modelfile.refiner`.
3. **Regenerate** baseline: `Tests/Invoke-RefinerBaseline.ps1 -Force` (N=20).
   Regenerate — do NOT hand-edit. (PR #50 lesson: corpus AND baseline both carry
   `acceptableModes`; a manual sync is the trap that paused #50.)
4. If the winner makes a bimodal case deterministic, **consider removing its
   `acceptableModes`** from the corpus so the test re-tightens to a single expected mode.
   Only if N=20 confirms ≥ 0.9 single-mode share.
5. Full Pester green (target 407/407).
6. Clean up candidate models: `ollama rm prompt-refiner-k5 prompt-refiner-p5 prompt-refiner-k5p5`.
7. Commit + PR.

## Risk

Tighter sampling makes the model greedier. Failure modes:
- A genuinely ambiguous input locks onto the *wrong* mode deterministically (worse than
  oscillating, because the bench then reports a stable regression).
- Borderline cases that legitimately admit both modes get forced one way, narrowing
  intended flexibility.

The Pareto gate catches both: a variant that improves the 2 targets but pushes any other
case past threshold is rejected.

## Out of scope

- `temperature`, `repeat_penalty`, `num_predict`, prompt/few-shot changes — this is a
  sampling-width-only experiment.
- Compiler model (`prompt-opt`) untouched.

## Cost

Phase A ≈ 40 min (3 candidates × 26 live cases × 10 trials, model warm).
Phase B ≈ 15 min (rebuild + N=20 regen + Pester).
