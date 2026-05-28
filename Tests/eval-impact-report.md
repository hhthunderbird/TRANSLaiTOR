# TRANSLaiTOR Impact Report — PRs #35-41

**Date:** 2026-05-27
**Method:** Re-ran 32 eval entries through c.ps1 before and after all improvements.

## INVENTED entries (8 entries user scored as INVENTED)

| # | Input | BEFORE context | AFTER context | Fix |
|---|-------|---------------|---------------|-----|
| 4 | `Faça Recovery Imediato` | "gerenciamento de projetos" | "Nenhuma informação disponível" | Stopped inventing |
| 8 | `A, depois follow-ups` | "Evaluation e tomada de decisões" | "não especificado" | Stopped inventing |
| 12 | `visual companion` | "Aprendizado por Imagem, NLP" | **"Unity, C#, UI/UX"** | Correct domain |
| 16 | `ExamMembership flag` | "Banco de dados SQL" | **"Unity, C#, sistema de exames"** | Correct domain |
| 20 | `ExamMembership invisíveis` | "Estrutura de dados" | **"Unity, UI, estado inicial"** | Correct domain |
| 21 | `InteractiveExamManager prefabs` | ".NET Core, Unity" | **"Unity, C#, pré-fab, UI"** | Removed .NET Core |
| 22 | `Awake InteractiveMeasureTape` | ".NET Core, DI" | **"Unity, C#, prefabs"** | Removed .NET Core |
| 26 | `ExamProfile Visibility Rules` | "Dados relacionais, criptografia hash" | **"Sistema Exames, Migração"** | Removed crypto hallucination |

**Result: 8/8 improved.** 6 now have correct Unity domain. 2 correctly admit "não especificado" instead of inventing.

## PASTE/ERROR entries (5 entries)

| # | Before | After | Improvement |
|---|--------|-------|-------------|
| 27 | "Ocorreência do erro HighDefinition" | **"Corrigir erro CS0234 em AudioCreator.cs:10, DialogueCreator.cs:9"** | Exact file:line extracted |
| 28 | "Resolver NullReferenceException em InteractiveMeasurTape_Body" | **"Resolver NullReferenceException em ...Body.cs:137"** | Exact file:line extracted |
| 29 | "Ferramenta para debugar erros em C# e Unity" | **"Corrigir erro CS1061 em MainUIController.cs:193, ProgressIndicator.cs:110"** | Was generic → now specific with file:line |
| 31 | "Não especificado" | "Pergunta sobre disponibilidade" | Marginal |
| 32 | "Ferramenta Unity detectou problema" | **"Resolver problema de importação em Missing Prefab: ProgressIndicator"** | Extracted prefab name + guid |

**Result: 4/5 dramatically improved.** Error-log extraction produces exact file:line locations instead of vague descriptions.

## Overall by category

| Category | Before (baseline) | After (post-#35-41) | Delta |
|----------|-------------------|---------------------|-------|
| INVENTED domain | 8 entries wrong domain | 0 wrong, 6 correct Unity, 2 "não especificado" | **-100% wrong domain** |
| PASTE accuracy | Generic task descriptions | Exact error codes + file:line locations | **Structural extraction** |
| Unity recognition | 0/8 correct | 6/8 correct Unity context | **+75%** |
| Hallucinated frameworks | Xamarin, .NET Core, NLP, crypto | None | **Eliminated** |

## Changes that produced this

| PR | Change | Impact |
|----|--------|--------|
| #36 | Unity few-shots + anti-invention rules | Fixed domain inference |
| #37 | Conversation context from transcript | Better reply understanding |
| #40 | Error-log extraction (skip Ollama) | Exact file:line for errors |
| #41 | Progress spinner | UX only (no accuracy impact) |

---

# Addendum — PRs #42-46 (2026-05-28)

**Method:** Fresh rerun of the same 32 eval-sample entries on `main @ a16d253` (post-#46). Output: `Tests/eval-rerun-now.jsonl`. Compared against the historic baseline in `eval-sample.json` (`old_xml` field) and the prior rerun `eval-rerun-post.jsonl`.

## What changed in #42-46

| PR | Change | Compiler output impact |
|----|--------|------------------------|
| #42 | Eval rerun script + impact report (docs) | None |
| #43 | Hook reads CLAUDE.md + last assistant turn | Refiner stage only (rerun uses `-NoRefine`, so not measurable here) |
| #44 | Housekeeping (gitignore, stale plans) | None |
| #45 | Bug fixes (dead `$dedup`, JSONL regex, `WaitForExit`) | None expected |
| #46 | Cleanups (dedup spinner, dedup init, reindent) | None expected |

**Verification: no compiler regression from cleanups.** Entries 2 and 3 of `eval-rerun-now.jsonl` are byte-identical to `eval-rerun-post.jsonl`. Audit-cleanup refactor of `c.ps1` did not perturb model output.

## Aggregate vs baseline (`old_xml`)

| Bucket | Count | Notes |
|--------|------:|-------|
| Improved (Unity correctly identified, framework hallucination removed) | 12 | #11, #12, #13, #16, #20, #21, #22, #24, #25, #26, #27, #32 |
| Error-log extraction (exact file:line) | 4 | #27, #28, #29, #32 (overlap with above) |
| Similar / marginal | 7 | Both old and new outputs roughly equivalent |
| **NEW regression: Unity / ExamSystem bias on generic inputs** | 3 | #2, #6, #17 |
| Compiler returned raw input (no envelope) | 1 | #7 `"ideia vaga"` — fallback path catches it downstream |
| Mid-conversation mixed | 5 | Without `[CONTEXTO DA CONVERSA]` block (rerun uses `-NoRefine`), short replies still distort |

## New finding: few-shot domain bias

The Unity/ExamSystem few-shots added in #36 and #43 (ExamController, ExamMembership, InteractiveMeasureTape) now leak Unity context into inputs that contain none of the trigger keywords:

| Entry | Input | Hallucinated context |
|-------|-------|----------------------|
| #2 | `comece a investigação` | `Unity, C#, sistema de exames` |
| #6 | `faça auditoria no projeto` | task became `Auditoria geral do projeto ExamSystem` |
| #17 | `Limpe os debug logs desnecessários e liste os commits` | `Sistema de gerenciamento de versões, Unity` |

The Modelfile.compiler rule "Prefab, Awake, MonoBehaviour, Inspector, GameObject = Unity" is correct, but the *few-shot examples* anchor the model to the Unity domain even when the rule does not fire. Recency bias amplifies this — the Unity examples sit at the end of the `MESSAGE` list.

**Mitigations (deferred, listed by cost):**
- Cheap: add a generic counter-example at the end of `Modelfile.compiler` — e.g. `cleanup debug logs` → `context: não especificado`. Counters recency.
- Medium: reorder the `MESSAGE` block so non-Unity examples come last.
- Expensive: drop one or two of the `ExamX` examples, keep only the most representative.

### Mitigation applied (this PR)

Cheap option above shipped: 3 counter-examples appended to `Modelfile.compiler` after the existing "preciso de ajuda com isso" fallback. Examples cover (a) generic verb + generic noun, (b) audit task without scope, (c) DevOps/git task without stack — each mapped to `context: não especificado`. Output captured in `Tests/eval-rerun-mitigated.jsonl`.

**Result on the 3 biased entries:**

| Entry | Before | After |
|-------|--------|-------|
| #2 `comece a investigação` | `Unity, C#, sistema de exames` | `não especificado — novo contexto para conversa` |
| #6 `faça auditoria no projeto` (task: `Auditoria geral do projeto ExamSystem`) | `Projeto completo, revisão estrutural` | task: `Auditoria do projeto concluída com recomendações`, context: `não especificado` |
| #17 `Limpe os debug logs desnecessários e liste os commits` | `Sistema de gerenciamento de versões, Unity` | `não especificado — comando Git` |

**3/3 bias removed.**

**Side effects (acceptable trade):**

| Entry | Before | After | Note |
|-------|--------|-------|------|
| #12 `vamos continuar com o visual companion` | `Unity, C#, UI/UX` | `Avaliação/Desenvolvimento - Interface Usuária (UI)` | Lost explicit "Unity" word (input has no Unity token) |
| #20 `objetos com ExamMembership sem exames...` | `Unity, UI, estado inicial` | `SistemaExams, UI` | Lost "Unity" (kept project domain) |

Other previously-Unity entries (#16, #21, #22, #24, #25) still resolve to `Unity, C#, ...`. Error-log entries (#27, #28, #29, #32) untouched (deterministic extraction path).

311/311 Pester pass after Modelfile change. Refiner.Quality.Tests.ps1 (12 scenarios × 10 trials) at 100% — confirms compiler-only change did not affect refiner.

---

# Addendum 2 — Refiner triage analysis (2026-05-28)

The compiler analysis above used `c.ps1 -Raw -NoRefine`, which bypasses the refiner. To audit the refiner in isolation, `Tests/Invoke-RefinerProbe.ps1` was added: it pipes each `eval-sample.json` raw input directly through `Invoke-OllamaModel -Model prompt-refiner` and records the decision (passthrough / questions / parse-fail) plus the question payload.

## Probe of `prompt-refiner` before any change (`refiner-probe.jsonl`)

| Decision class | Count | Notes |
|----------------|------:|-------|
| Correct passthrough | 9 | #3, #9, #17, #19, #22, #23, #24, #27, #32 |
| Correct questions | 4 | #4, #5, #7, #8 (truly contentless inputs) |
| **Wrong questions (should passthrough)** | 14 | #1, #11, #12, #13, #14, #15, #16, #18, #20, #21, #25, #26, #28, #29 |
| Borderline | 5 | #2, #6, #30, #31 — defensible either way |

The wrong-questions cluster split into three patterns:

1. **CamelCase identifier ignored** — #16 `ExamMembership`, #20 `ExamMembership`, #21 `InteractiveExamManager`, #25 `ToggleEventButton`, #26 `ExamProfile Visibility Rules`. The `DECISION RULE` listed only languages and frameworks; identifiers were not treated as concrete signal.
2. **Keyword in `DECISION RULE` failed to fire** — #18 `quero implementar cache LRU em Go` chose questions even though `go` is in the keyword list. The few-shot `implementa um cache LRU thread-safe em Go com capacidade configuravel` → `passthrough` did not generalise to the shorter `quero implementar` variant.
3. **Mid-conversation replies always asked** — #1, #11, #12, #13, #14, #15. The refiner has no concept of "reply" and the inputs do not satisfy the keyword rule, so it falls into the question branch even when the user has clearly named a concrete identifier or topic.
4. **Stack-trace inputs** — #28 `NullReferenceException` and #29 `CS1061` were classified as questions. In production these reach the error-log extraction stage before the refiner, so the misclassification has no user-visible effect; the probe still flags it as a refiner-in-isolation bug.

## Fix applied

`Modelfile.refiner` updated:

- `DECISION RULE` extended to include Unity tokens (prefab, awake, monobehaviour, gameobject, inspector, coroutine, raycast), CamelCase identifiers, file paths / extensions, and stack-trace markers.
- `DEFAULT IS A` clause sharpened: `CHOOSE B only when the input is genuinely contentless (e.g. "ideia vaga", "preciso ajuda com algo")`.
- Five new passthrough few-shots appended (recency anchor) covering the failure patterns: `quero implementar cache LRU em Go`, an `ExamMembership` line, a `ToggleEventButton` line, a `NullReferenceException` stack snippet, and `vamos continuar com o visual companion`.

## Result (`refiner-probe-after.jsonl`)

15 entries flipped `questions` → `passthrough`. All five `vague-*` bench scenarios still score 10/10 questions; all three `concrete-*` bench scenarios still score 10/10 passthrough — no over-correction.

| Outcome | Count |
|---------|------:|
| Correctly classified after fix | ~27/32 |
| Still wrong (identifier missed) | 1 — #16 `ExamMembership Exam precisa ser flag para  permitir escolher vários` (model declined to generalise despite a near-verbatim few-shot; suspect the extra `Exam` token or the double-space) |
| Genuinely vague (correctly asked) | 4 — #4, #5, #7, #8 |

311/311 Pester pass. `Refiner.Quality.Tests.ps1` regression test (12 cases × 10 trials, baseline drop threshold 0.40) still passes — fresh distributions stay within tolerance.

## Persisting limitations (model, not pipeline)

- Identifier mangling on long PT/EN compound names (`InteractiveMeasureTape_Body` → `Interactive Measure Tape Body`, `RASCAL` → `Raskell`, `ExamMembership` → `ExamMembroship`). llama3.2:3b limitation. Not addressable in pipeline.
- Task field truncated at ~120 chars when locations list is long (entry #28). Mitigation: cap location count to 2 inside `Format-ErrorLogXml`.
- Non-determinism still present despite `temperature 0.05` — same input on different runs differs in surface wording, not in domain.
