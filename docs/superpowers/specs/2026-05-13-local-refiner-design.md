# Local Refiner — Design Spec

**Date:** 2026-05-13
**Status:** Approved (verbal, this branch)
**Branch:** `feat/local-refiner`

## Problem

The current pipeline (`c.ps1` → `prompt-opt` Ollama model → Claude CLI) treats
all user inputs the same. When the user types a vague prompt
(e.g. `c "preciso ajuda com cache"`), the small local model has no choice but
to hallucinate or inject a generic `<context>` tag. This wastes the eventual
Claude tokens spent on a vague distilled prompt and degrades the quality of
the downstream AI response — the opposite of the project's stated purpose.

## Goals

1. Detect ambiguous user input before paying any Claude tokens.
2. Interactively clarify ambiguity with 1–3 terminal questions.
3. Pass an enriched input to the existing compiler model.
4. Keep the whole stage local (Ollama), zero cloud cost per use.
5. Preserve all existing behavior for already-clear inputs (pass-through fast).
6. Stay scriptable: `-Raw` mode must remain non-interactive.

## Non-Goals

- Multiple domain-specialized models (deferred; YAGNI).
- A Claude Code subagent "meta-interviewer" for project planning
  (deferred to a separate branch).
- Auto-pasting the distilled output into a third-party AI window
  (out of scope; needs OS-level hooks).
- Caching the refiner's output (the same raw input can be refined into
  different enriched inputs depending on the user's answers, so caching
  the refiner step would be wrong).

## Architecture

```
c.ps1
 ├─ Stage 1: REFINER       ollama run prompt-refiner
 │    in:  raw user input
 │    out: <passthrough>...</passthrough>   (input is already clear)
 │         <questions><q>...</q></questions> (1–3 clarifying questions)
 │    if questions → terminal prompts user → answers merged into input
 │
 ├─ Stage 2: COMPILER      ollama run prompt-opt   (unchanged)
 │    in:  enriched (or unchanged passthrough) input
 │    out: <task>...</task><context>...</context><constraints>...</constraints>
 │
 └─ Stage 3: SINK
        clipboard  (default)
        claude -p  (-Send)
        stdout     (-Raw)
```

### New files

- `Modelfile.refiner` — Ollama Modelfile dedicated to the refinement step.
- `docs/superpowers/specs/2026-05-13-local-refiner-design.md` — this spec.

### Renamed files

- The existing `ModelFile` becomes `Modelfile.compiler`. This avoids
  ambiguity once a second Modelfile lives in the repo and matches Ollama's
  canonical filename casing. `README.md`, the `ollama create` instructions,
  and any scripted references update accordingly.

### Modified files

- `cprompt.psm1` — new pure helpers:
  - `Get-RefinerOutput [string]$RawOutput` — parses one of the two refiner
    response shapes; returns `@{ Mode = 'passthrough' | 'questions';
    Payload = <string> | <string[]> }` or `$null` on failure.
  - `Test-RefinerOutput [hashtable]$Parsed` — boolean validity check.
- `c.ps1` — adds the refiner stage before the existing compiler call:
  - New switch `-NoRefine` (bypass the refiner entirely).
  - `-Raw` implies `-NoRefine` (scripted use cannot prompt interactively).
  - History entries gain an optional `rawInput` field next to `input`;
    when no refinement occurred they are equal.
- `Tests/cprompt.Tests.ps1` — TDD coverage for the two new helpers.
- `README.md` — install instructions list both Modelfiles, document
  `-NoRefine` and the interactive flow.

## Refiner output contract

The refiner emits **exactly one** of:

```
<passthrough>verbatim original input</passthrough>
```

or

```
<questions>
<q>first clarifying question?</q>
<q>second clarifying question?</q>
</questions>
```

Rules enforced in the Modelfile system prompt:

- Always exactly one of the two shapes. Never both. Never prose.
- `<questions>` contains 1 to 3 `<q>` elements, no more.
- Questions are direct, single-sentence, oriented to fill a missing slot:
  language, stack, runtime, scale, primary direction (read/write),
  acceptance criterion.
- If the input already names a stack AND a concrete action, prefer
  `<passthrough>`. Bias toward passthrough when in doubt — false-positive
  questions are more annoying than a passthrough that yields a generic
  `<context>` downstream.

### Salvage

`Get-RefinerOutput` mirrors the salvage philosophy of `Get-PromptXml`:
- Strips BOM.
- Extracts the outer block (`<passthrough>` or `<questions>`) defensively,
  tolerating a hallucinated close tag (`</pass>`, `</question>`, etc.).
- For `<questions>`, extracts each `<q>...</q>` independently, trims, drops
  empty entries, caps at 3.
- Returns `$null` when no recognizable shape is found — caller treats this
  as "refiner failed, skip refinement, send input through unchanged".

## Interactive flow (terminal)

```
$ c "preciso ajuda com cache"
--- refinando input ---
1) qual stack/runtime?
> Python + Redis
2) leitura ou escrita predominante?
> leitura, 100x mais
--- destilando prompt local (prompt-opt) ---
<task>...</task><context>Python, Redis, cache leitura-pesada</context>...
```

Prompting is done with `Read-Host`. Each `<q>` becomes one prompt.
- Empty answer → that question is dropped from the enriched input.
- Ctrl+C → abort the whole run with non-zero exit.
- The enriched input format is:
  `"<raw input>\n\n<Q1>: <A1>\n<Q2>: <A2>\n..."`.

## Error handling

| Failure                              | Behavior                              | Exit |
|--------------------------------------|---------------------------------------|------|
| Refiner Ollama call non-zero exit    | Skip refinement, pass raw to compiler | 0 (log only) |
| Refiner output unparseable           | Skip refinement, pass raw to compiler | 0 (log only) |
| Refiner returns `<questions>`, user  | Use whatever the user answered;       | 0 |
|   answers some, skips others         | drop the skipped Q/A pair             |      |
| Ctrl+C during answer prompt          | Abort the run                         | 130 |
| Compiler fails (existing paths)      | Unchanged from current behavior       | 5/6  |

The refiner is a best-effort enhancement. Its failure must NEVER block
the existing happy path.

## Cache + history

- Cache key continues to be `(compiler model name, final input)`. Because
  the final input now reflects any user answers, repeated runs with
  different answers will not collide. Same raw input, same answers, will
  hit cache.
- History entry shape grows:
  ```json
  {
    "ts": "...",
    "model": "prompt-opt",
    "rawInput": "preciso ajuda com cache",
    "input": "preciso ajuda com cache\n\nqual stack: Python + Redis\n...",
    "xml": "<task>...</task>...",
    "cached": false,
    "refined": true
  }
  ```
  When no refinement occurs (`-NoRefine` or `<passthrough>`), `rawInput`
  equals `input` and `refined` is `false`.

## Testing

TDD for both new helpers:

- `Get-RefinerOutput`:
  - Parses well-formed `<passthrough>` → Mode passthrough, Payload string.
  - Parses well-formed `<questions>` with 1, 2, and 3 `<q>` elements.
  - Caps at 3 even if model emits more.
  - Salvages hallucinated close tag (`</pass>`, `</question>`).
  - Returns `$null` on garbage input.
  - Trims question content; drops empty `<q></q>`.
- `Test-RefinerOutput`:
  - True for valid passthrough.
  - True for valid questions (1–3 non-empty).
  - False for empty questions list.
  - False for null / malformed.

Manual smoke test: vague prompt yields questions; specific prompt yields
passthrough; refiner failure (delete model) still runs compiler.

## Rollout

This is a non-breaking change. Existing invocations of `c "..."` still
work; the refiner adds a stage but defaults to passthrough on clear input.
Users who want the old behavior can pass `-NoRefine`. Scripts that pipe
`c "..." -Raw` get automatic bypass.

The branch ships when:

1. All Pester tests pass (existing 37 + new ones, ~10).
2. `ollama create prompt-refiner -f Modelfile.refiner` succeeds.
3. Manual smoke covers: vague → questions; specific → passthrough;
   refiner unavailable → graceful fallback; `-NoRefine`; `-Raw`.
