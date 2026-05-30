# Conversational / continuation bypass — design

**Date:** 2026-05-30
**Status:** approved, pre-implementation
**Branch (planned):** `feat/conversational-bypass`

## Problem

Multi-word continuation/meta prompts that carry **no task topic** —
e.g. `vamos continuar de onde paramos`, `lets continue where we left off` —
reach the prompt-opt **compiler**, which is forced to emit a
`<task>/<context>/<constraints>` envelope and therefore **hallucinates a
spec**. Observed this session: `vamos continuar de onde paramos` →
`<task>Criar um novo projeto com base nas recomendações do auditório
anterior</task>`.

### Mechanism (corrected framing)

This is a **compiler** failure, not a refiner one. In both the hook path and
any `-Raw` invocation, `-Raw` implies `-NoRefine` (`c.ps1:147`,
`hook:124`), so the refiner never runs. The garbled envelope is produced by
the prompt-opt compiler. This is **distinct** from the PR #52 cache-key bug
(stale XML served across contexts) — same symptom class ("short-prompt
hallucination"), different root cause.

The existing guard (`c-autorefine.ps1:48`) only catches **single-token**
replies: `^(yes|ok|continue|...)\W*$`. Multi-word continuations slip past it.

## Approach

Add a deterministic, curated **whole-prompt** discriminator. Optimize for
**precision, not recall** — the system is fail-soft in both directions
(Claude always sees the raw text; it recovered fine this session). A false
positive silently drops TRANSLaiTOR's value on a real task; a miss is mild
noise. So a short curated phrase list beats a semantic classifier.

**Boundary:** pure continuation/meta → bypass. Continuation **with a topic
noun** (`continua o parser`, `continue the auth refactor`) → still compiles,
because TRANSLaiTOR adds value there.

Rejected alternatives:
- Extending `Test-InputIsMetaQuery` — that detector is WH-word + `?`
  (interrogative). This category is imperative/declarative. Separate detector.
- Building synthetic `Format-ConversationalXml` — YAGNI. Bypass is raw
  passthrough (`exit 0` in hook; empty stdout in `-Raw`).

## Components

### `Test-InputIsConversational -Text` (new, in `cprompt.psm1`)

- Returns `$true` when the **entire trimmed prompt** matches a curated
  continuation/meta phrase, anchored `^...$`, case-insensitive, bilingual.
- Returns `$false` for empty/whitespace (consistent with
  `Test-InputIsMetaQuery`).
- A topic/technical token following the verb defeats the match.

Initial phrase set (whole-prompt, anchored):

- **PT:** `vamos continuar`, `continuar de onde paramos`,
  `vamos continuar de onde paramos`, `vamos na ordem`, `pode continuar`,
  `pode seguir`, `segue`, `continua`, `próximo` / `proximo`, `vamos`,
  `e agora` / `e agora?`, `o que falta` / `o que falta?`, `prossiga`
- **EN:** `lets continue` / `let's continue`,
  `continue where we left off`, `pick up where we left off`, `go on`,
  `keep going`, `whats left` / `what's left`, `what now`

(Exact regex finalized during TDD against the positive/negative table.)

### `c.ps1` — new bypass stage

After the error-log detector (`c.ps1:202-210`), before the refiner block:

```
if (-not $skipCompiler -and (Test-InputIsConversational -Text $userInput)) {
    $metricMode  = 'conversational'
    $skipRefiner = $true
    $skipCompiler = $true
    # $xml stays $null
}
```

Output handling:
- `-Raw`: `$xml` is `$null` → current tail writes empty stdout. Hook's
  `if (-not $xml) { exit 0 }` treats empty as passthrough. **Verify the tail
  does not crash on `$null` xml** (history/metrics writes use length guards
  already at `c.ps1:359`).
- Interactive: print `(prompt conversacional - sem destilacao)`, echo the raw
  text, **no** clipboard write. (Needs a small branch near `c.ps1:390-435`,
  since the normal path always sets clipboard / prints XML.)

### `c-autorefine.ps1` — hook pre-filter

Reuse the module function instead of duplicating the regex:

```
try { Import-Module 'C:\Projetos\TRANSLaiTOR\cprompt.psm1' -Force -ErrorAction Stop } catch {}
if ((Get-Command Test-InputIsConversational -ErrorAction SilentlyContinue) `
    -and (Test-InputIsConversational -Text $trim)) { exit 0 }
```

Placed after the existing single-token `$conversational` check
(`hook:48-49`). Fail-open: if the import fails the hook proceeds as today.
The single-token regex stays as a cheap first cut.

## Data flow

```
prompt → hook: trim/length/slash/single-token gates
            → Test-InputIsConversational? ── yes → exit 0 (raw passthrough)
            → no → c.ps1 -Raw
                     → Test-InputIsConversational? ── yes → empty stdout → hook exit 0
                     → no → compiler → XML envelope
```

Defense in depth: both layers run the same check. Hook layer saves an ollama
spawn; c.ps1 layer guarantees parity for direct interactive use.

## Error handling

- Empty/whitespace input → `$false` (never bypasses on empties; other gates
  own those).
- Module load failure in hook → caught, hook proceeds (fail-open preserved).
- `$null` xml in `c.ps1` metrics/history tail → already length-guarded; add an
  explicit check if any write assumes non-null.

## Testing

TDD. The positive/negative table **is** the discriminator spec.

**Positive (bypass):** `vamos continuar de onde paramos`, `vamos na ordem`,
`lets continue`, `continue where we left off`, `pode seguir`, `o que falta?`,
`próximo`.

**Negative (compile):** `continua o parser`, `continue the auth refactor`,
`vamos refatorar o cache`, `adiciona testes ao módulo X`, `next: implement
retry logic`, `o que falta no parser de XML?` (topic present), empty string,
whitespace.

Locations:
- Unit table → `Tests/cprompt.Tests.ps1` (new `Describe`/`Context`).
- `c.ps1` stage → assert `mode=conversational`, no clipboard, empty `-Raw`
  stdout (extend `Tests/c.Tests.ps1`).
- Hook → assert `exit 0` + no output for a positive phrase
  (`Tests/c.AutorefineHook.Tests.ps1`).

**Cache gotcha (from [[cache-key-context-bug]]):** the garbled XML for
`vamos continuar de onde paramos` + this session's context is now **cached**
(PR #52 key = Model+Text+Context; it was a valid envelope, so not marked
fallback). Unit tests are unaffected (detector short-circuits before cache),
but **any end-to-end smoke must pass `-NoCache`** or cached garbage masks the
fix.

## Out of scope

- Semantic / model-based classification of conversational intent.
- Synthetic XML for conversational prompts.
- Touching the refiner or its Modelfile.
- Reworking the single-token regex at `hook:48`.
