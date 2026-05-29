# Refiner Sampling Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten `prompt-refiner` sampling (top_k 20→5, top_p 0.7→0.5) to eliminate bimodal mode-oscillation on 2 borderline cases — but only if Pareto (improve the 2, regress none).

**Architecture:** Two-phase experiment. Phase A builds 3 candidate Ollama models and benches each against the 28-case corpus without mutating committed state (baseline.json or the live model). A unit-tested offline helper computes max-mode-share + regression flags from bench JSON to pick a Pareto winner. Phase B applies the winner only, regenerates the baseline, and runs full regression.

**Tech Stack:** PowerShell 5.1, Pester 5.7.1, Ollama (llama3.2:3b), existing `Tools/refiner-bench.ps1` + `Tests/Invoke-RefinerBaseline.ps1`.

---

## Overview

Run a controlled sampling-width experiment on `prompt-refiner` to kill bimodal
oscillation on 2 borderline corpus cases. Build 3 candidate Ollama models varying
`top_k`/`top_p`, bench each against the 28-case corpus without touching the committed
baseline, and apply the change only if a variant is Pareto (improves the 2 targets, zero
regression elsewhere).

## Current State

- `Modelfile.refiner`: `top_k 20`, `top_p 0.7`, `temperature 0.05` (lines 4-6).
- `prompt-refiner:latest` live in `ollama list`.
- `bench-results/baseline.json` — N=20 reference, 26 live cases, committed.
- `Tools/refiner-bench.ps1` — takes `-RefinerModel`/`-Trials`, writes
  `bench-results/bench-<timestamp>.json`, never touches baseline. Each case result has
  `modeCounts {passthrough, questions, invalid}`.
- Branch `chore/refiner-sampling-tuning`, spec committed `b9cc915`.
- 2 bimodal cases: `camelcase-exam-profile-rules`, `keyword-go-cache-lru-short`.

## Desired End State

Either:
- **(A) Pareto winner found** — `Modelfile.refiner` updated, `prompt-refiner` rebuilt,
  `baseline.json` regenerated N=20, full Pester 407/407, candidate models removed,
  PR opened. Verify: `git log` shows tuning commit; `ollama list` has no
  `prompt-refiner-*` candidates; Pester green.
- **(B) No winner** — Modelfile unchanged, finding documented in spec + memory, PR
  optional (docs-only) or branch abandoned with a recorded note. Verify: `git diff main
  -- Modelfile.refiner` empty.

## Key Discoveries

- `quero implementar cache LRU em Go` is a **literal passthrough few-shot**
  (`Modelfile.refiner:78`) yet oscillates — confirms width, not prompt, is the cause.
- Bench writes a self-contained JSON with per-case `modeCounts` — max-mode-share is
  `max(modeCounts.values) / trials`, computable from existing output. No bench changes
  needed.
- `Invoke-RefinerBaseline.ps1 -Force` regenerates baseline from corpus — the supported
  path. PR #50 trap: never hand-edit baseline acceptableModes.

## What We're NOT Doing

- No changes to `temperature`, `repeat_penalty`, `num_predict`, `num_ctx`, prompt text,
  or few-shots.
- No compiler (`prompt-opt`) changes.
- No new params beyond top_k/top_p.
- No grid beyond the 3 candidates (k5, p5, k5p5).

## Implementation Approach

Cheap→expensive. Phase A is read-only w.r.t. committed state (candidate models +
timestamped bench files only). Only after a Pareto winner is confirmed do we mutate
`Modelfile.refiner` and regenerate the baseline (Phase B). The analysis helper is the
only new code and is unit-testable on fixture JSON without Ollama.

---

## Milestone 1: Analysis helper

### Overview
A function that ingests bench JSON(s) + baseline and reports, per case: max-mode-share,
dominant mode, expected-hit rate, and a regression flag vs baseline. This is the
decision instrument — must be trustworthy and testable offline.

### Task 1.1: Write the analysis function with tests

**Files:**
- `Tools/Compare-RefinerBench.ps1` - new; analysis helper (script or dot-sourceable function).
- `Tests/Compare-RefinerBench.Tests.ps1` - new; Pester unit tests on synthetic fixtures.

**Step 1: Write the test**
Pester tests covering:
- max-mode-share = max(modeCounts)/trials (e.g. {pt:10,q:0,inv:0}→1.0; {pt:5,q:5}→0.5).
- dominant mode = key of max count; ties broken deterministically (document the rule).
- expected-hit reads `acceptableModes` when present, else `expectedMode` (mirror
  `Get-RefinerRegressions` semantics in `cprompt.psm1:747`).
- regression flag = candidate expected-hit drops below baseline by > DropThreshold (reuse
  0.40 default) OR below the Quality absolute floor (passthrough/questions 0.6).
- returns one row per live case; skips `rejected`.
- handles a case present in candidate but absent in baseline (and vice-versa) without
  throwing.

**Step 2: Implement**
Function takes baseline path + one-or-more candidate bench paths, emits a comparison
table (objects) and a summary (per-variant: #improved-bimodal, #regressions). Pure data
in / data out — no Ollama, no file writes beyond optional report.

**Step 3: Verify**
```powershell
Invoke-Pester .\Tests\Compare-RefinerBench.Tests.ps1 -Output Detailed
```
Expected: all green.

### Verification
Helper computes correct shares/regressions on hand-built fixtures with known answers.

---

## Milestone 2: Phase A — candidate builds + bench

### Overview
Produce 3 candidate models and their bench results. Baseline and live model untouched.

### Task 2.1: Generate candidate Modelfiles + build models

**Files:**
- temp Modelfiles (e.g. `bench-results/Modelfile.refiner.k5`, `.p5`, `.k5p5`) — NOT committed.

**Step 1:** Copy `Modelfile.refiner`, change only the two PARAMETER lines per variant
(K5: top_k 5 / top_p 0.7; P5: top_k 20 / top_p 0.5; K5P5: top_k 5 / top_p 0.5).

**Step 2:** Build each:
```powershell
ollama create prompt-refiner-k5   -f bench-results/Modelfile.refiner.k5
ollama create prompt-refiner-p5   -f bench-results/Modelfile.refiner.p5
ollama create prompt-refiner-k5p5 -f bench-results/Modelfile.refiner.k5p5
```

**Step 3: Verify**
```powershell
ollama list | Select-String 'prompt-refiner-'
```
Expected: 3 candidate rows.

### Task 2.2: Bench each candidate (N=10)

**Step 1:** Run, capturing each output path:
```powershell
.\Tools\refiner-bench.ps1 -RefinerModel prompt-refiner-k5   -Trials 10
.\Tools\refiner-bench.ps1 -RefinerModel prompt-refiner-p5   -Trials 10
.\Tools\refiner-bench.ps1 -RefinerModel prompt-refiner-k5p5 -Trials 10
```
(Optional control: `-RefinerModel prompt-refiner -Trials 10` for apples-to-apples N=10.)

**Step 2: Verify**
```powershell
Get-ChildItem bench-results\bench-*.json | Select-Object Name,LastWriteTime
```
Expected: 3 (or 4) fresh bench files.

Confirm `baseline.json` untouched:
```powershell
git status --porcelain bench-results/baseline.json
```
Expected: empty.

### Verification
3 candidate bench JSONs exist; baseline unchanged; live `prompt-refiner` unchanged.

---

## Milestone 3: Decision

### Overview
Apply the helper, decide Pareto winner or no-go.

### Task 3.1: Run comparison + record findings

**Step 1:** Feed baseline + 3 candidate benches to `Compare-RefinerBench.ps1`.

**Step 2:** Read the table. For each variant record: bimodal max-mode-share (target ↑),
regression count (must be 0). Prefer the **single-param** variant if it matches the
double (smaller change).

**Step 3:** Append a "Results" section to the spec with the actual numbers (before/after
per bimodal case, regression scan summary).

**Decision branch:**
- **Winner exists** → Milestone 4.
- **No winner** → document in spec + memory, `ollama rm` candidates, stop. Branch is
  docs-only (spec + helper + plan). Decide with user whether to PR the tooling or abandon.

### Verification
Spec has a Results section with real numbers and an explicit winner/no-winner call.

---

## Milestone 4: Phase B — apply (only if winner)

### Overview
Promote the winning params to the live model, re-establish the baseline, full regression.

### Task 4.1: Update Modelfile + rebuild live model

**Files:**
- `Modelfile.refiner` - change the two PARAMETER lines to the winner's values.

**Step 1:** Edit lines 5-6 (or 4-6) to winning top_k/top_p.

**Step 2:** Rebuild:
```powershell
ollama create prompt-refiner -f Modelfile.refiner
```

**Step 3: Verify**
```powershell
ollama show prompt-refiner --modelfile | Select-String 'top_k|top_p'
```
Expected: winner's values.

### Task 4.2: Regenerate baseline (N=20)

**Step 1:**
```powershell
.\Tests\Invoke-RefinerBaseline.ps1 -Force
```
(Regenerate — never hand-edit. PR #50 lesson.)

**Step 2: Verify**
```powershell
git diff --stat bench-results/baseline.json
```
Expected: baseline.json modified, parses as JSON, 26 live cases.

### Task 4.3: Re-tighten acceptableModes (conditional)

If a bimodal case now shows ≥ 0.9 single-mode share at N=20, remove its `acceptableModes`
from `Tests/fixtures/refiner-corpus.json` so the test re-asserts a single expected mode,
then re-run `Invoke-RefinerBaseline.ps1 -Force` so corpus + baseline stay in sync.
Skip if the case is still mixed.

**Verify:** corpus and baseline acceptableModes match (the drift check from PR #50).

### Task 4.4: Full Pester + cleanup

**Step 1:**
```powershell
Invoke-Pester .\Tests -Output Detailed
```
Expected: 407/407 (or new total if Task 4.3 changed a case), 0 failed.

**Step 2:** Remove candidates + temp Modelfiles:
```powershell
ollama rm prompt-refiner-k5 prompt-refiner-p5 prompt-refiner-k5p5
Remove-Item bench-results/Modelfile.refiner.* -ErrorAction SilentlyContinue
```

**Step 3: Verify**
```powershell
ollama list | Select-String 'prompt-refiner-'   # expect nothing
git status --porcelain                            # only intended files
```

### Verification
Modelfile updated, baseline regenerated + in sync with corpus, Pester green, no candidate
models or temp files left.

---

## Milestone 5: Ship

### Task 5.1: Pre-push audit + PR

**Step 1:** Pre-push audit (memory discipline): `git diff --cached --stat`, full Pester
green, review diff out loud.

**Step 2:** Decide which bench-* artifacts to commit (likely the winning candidate's, or
none — exploratory benches can stay local/gitignored). State the choice.

**Step 3:** Commit, push, `gh pr create` against main.

### Verification
PR open; main-targeted; clean tree.

---

## Testing Strategy

- **Unit:** `Compare-RefinerBench.Tests.ps1` validates the decision instrument offline.
- **Statistical:** `refiner-bench.ps1` N=10 (Phase A screen) → N=20 baseline (Phase B
  confirm).
- **Regression:** full `Refiner.Quality.Tests.ps1` (live model vs baseline) + whole suite.

## Rollback Plan

- Phase A leaves nothing committed-state-mutating: `ollama rm prompt-refiner-*`, delete
  temp Modelfiles, done.
- Phase B: if Pester regresses after rebuild, `git checkout Modelfile.refiner
  bench-results/baseline.json` and `ollama create prompt-refiner -f Modelfile.refiner` to
  restore the original live model. Branch can be deleted; main never touched until merge.

## State Tracking

- [ ] M1: analysis helper + tests green
- [ ] M2: 3 candidates built + benched, baseline untouched
- [ ] M3: comparison run, Results section written, winner/no-winner decided
- [ ] M4: (if winner) Modelfile + baseline + Pester + cleanup
- [ ] M5: (if winner) audit + PR
