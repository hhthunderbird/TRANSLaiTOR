# Meta-Query Detection + Context Injection

Date: 2026-05-24
Status: design approved, awaiting plan

## Problem

When users run `c "o que temos para fazer agora?"` (or any status/meta question),
the pipeline fails gracefully but uselessly:

1. Refiner sees WH-word without concrete detail, emits `<questions>` mode
2. Without `-Interactive`, questions are skipped, raw input passes through
3. Compiler receives vague input, produces garbage XML (`<task>Fim da sessao</task>`)

The autorefine hook (`c-autorefine.ps1:53-54`) detects meta-questions and exits
early — but that just passes the raw prompt to Claude Code with no project context.

Neither path gives the user useful output.

## Solution

Add a **meta-query stage** to the pipeline that:

1. Detects status/meta questions (WH-word + project-state marker)
2. Gathers project context (git, TODOs, project files) with visible progress
3. Builds a synthetic `<task>/<context>/<constraints>` XML envelope
4. Skips refiner + compiler entirely

## Non-goals

- Answering the meta-question (that is Claude's job)
- Replacing the refiner or compiler for normal task prompts
- Adding new Ollama models or changing existing Modelfiles
- Supporting non-git project directories (git required)

## Detection: `Test-InputIsMetaQuery`

Location: `cprompt.psm1` (new exported function)

Requires BOTH:
- **WH-word**: `qual|que|o que|por que|como|quando|onde|what|why|how|when|where|which|who|whose`
- **State-marker**: `agora|falta|próximo|pendente|restante|now|left|next|current|todo|remaining|status|progress`

```powershell
$whWord      = '(qual|que|o que|por que|como|quando|onde|what|why|how|when|where|which|who|whose)'
$stateMarker = '(agora|falta|pr[oó]ximo|pendente|restante|now|left|next|current|todo|remaining|status|progress)'
$pattern     = "(?i)^\s*$whWord\b.*\b$stateMarker\b.*\?\s*$"
```

True positives:
- `"o que temos para fazer agora?"` -> true
- `"what's left to do?"` -> true
- `"o que falta?"` -> true
- `"qual o proximo passo?"` -> true
- `"where are we now?"` -> true
- `"what is the current status?"` -> true

True negatives (coding questions):
- `"como faco cache LRU em Go?"` -> false
- `"what's the best way to handle errors?"` -> false
- `"how do I create a REST endpoint?"` -> false
- `"qual a melhor lib para testes?"` -> false
- `"why is this query slow?"` -> false

Single source of truth: both CLI `c` and autorefine hook use this function.
Hook's separate meta-question regex (lines 51-54) is deleted.

## Context Gathering: `Get-ProjectContext`

Location: `cprompt.psm1` (new exported function)

```powershell
Get-ProjectContext [-Path <dir>] [-OnProgress <scriptblock>] [-BudgetMs <int>]
```

Gathers 4 sources sequentially with progress feedback:

| Step | Source | Command | Bounds | Progress |
|------|--------|---------|--------|----------|
| 1 | Git status | `git status --short` | inherently bounded | `[1/4] git status...` |
| 2 | Git log + branch | `git log --oneline -15`, `git branch --show-current` | 15 entries | `[2/4] git log...` |
| 3 | TODO markers | `grep -rn 'TODO\|FIXME\|HACK'` | files from `git diff --name-only HEAD~50` only, 5s timeout, 30 line cap | `[3/4] scanning TODOs...` |
| 4 | Project files | Read CLAUDE.md, README.md | 2000 chars each, only if exist | `[4/4] project files...` |

`-OnProgress` callback receives step strings. `c.ps1` passes
`{ Write-Host $_ -ForegroundColor DarkGray }`.

`-BudgetMs` (default: unlimited): elapsed-time budget. If exceeded before step 3
(TODOs), skip TODO scan. Useful for hook context where latency matters.

Returns hashtable:
```powershell
@{
    Branch       = 'main'
    Status       = '?? newfile.cs ...'
    Log          = 'abc1234 last commit ...'
    Todos        = 'src/foo.cs:42: // TODO fix ...'   # or $null if skipped
    ProjectFiles = @{ 'CLAUDE.md' = '...'; 'README.md' = '...' }
    ElapsedMs    = 1234
}
```

## Output: `Format-MetaQueryXml`

Location: `cprompt.psm1` (new exported function)

Builds synthetic XML envelope from gathered context + original question.
Uses standard `<task>/<context>/<constraints>` shape so hook's existing
envelope regex (line 84) validates without changes.

```powershell
Format-MetaQueryXml [-Question <string>] [-Context <hashtable>]
```

Example output:
```xml
<task>Responder consulta de status do projeto</task><context>Branch: main | Modified: 2 files | Recent: abc1234 fix auth, def456 add tests | TODOs: 3 items | CLAUDE.md: present</context><constraints>Listar trabalho pendente, estado atual do repositorio, proximos passos</constraints>
```

Task tag is fixed string (not LLM-generated). Context tag contains gathered data,
pipe-delimited. Constraints tag is fixed guidance string.

## Pipeline Integration: `c.ps1`

New stage between pregate (line 132) and refiner (line 134):

```
input -> pregate -> META-QUERY CHECK -> refiner -> compiler -> output
```

New parameter: `-MetaQuery` switch — force meta-query path regardless of detection.
Manual override for testing.

Flow when meta-query detected (or `-MetaQuery` forced):
1. Print `"--- consulta de status detectada ---"` (DarkCyan)
2. Compute budget: if `-NonInteractive` is set, pass `-BudgetMs 3000`; otherwise no budget
3. Call `Get-ProjectContext` with progress callback and budget
4. Call `Format-MetaQueryXml` with original question + gathered context
4. Set `$metricMode = 'meta-query'`, `$xml = $result`
5. Jump to output (line 260+), skip refiner + compiler

Metrics: `mode = 'meta-query'`. `refinerMs` and `compilerMs` = 0.
New field `contextGatherMs` records gathering duration.

## Hook Integration: `c-autorefine.ps1`

Delete hook's separate meta-question regex (lines 51-54). The hook already
calls `c.ps1` for all qualifying inputs (line 75). `Test-InputIsMetaQuery`
inside `c.ps1` handles detection.

Hook invocation unchanged:
```powershell
$xml = & $cps -NonInteractive -Raw $trim 2>$null 3>$null 6>$null
```

When input is a meta-query, `c.ps1` internally enters meta-query path and
returns synthetic XML. Hook's envelope check (line 84) validates it.

Latency concern: hook blocks Claude Code synchronously. `Get-ProjectContext`
called with `-BudgetMs 3000` in hook context to skip TODO step if slow.
This is handled by `c.ps1` detecting hook context via `-NonInteractive` flag:
when `-NonInteractive` is set, pass `-BudgetMs 3000` to `Get-ProjectContext`.

## Testing

### Unit tests (`Tests/cprompt.Tests.ps1`)

**`Test-InputIsMetaQuery`**:
- 6+ true positive cases (meta-queries with state markers)
- 5+ true negative cases (coding questions with WH-words but no state markers)
- Edge cases: null, empty, whitespace, no question mark, state marker without WH-word

**`Get-ProjectContext`**:
- Mock git commands, verify hashtable shape and keys
- Verify progress callback fires 4 times (or 3 if TODO skipped)
- Verify TODO output capped at 30 lines
- Verify project file content capped at 2000 chars
- Verify `-BudgetMs` skips TODO step when budget exceeded

**`Format-MetaQueryXml`**:
- Verify output matches hook's envelope regex
- Verify all context sections present in output
- Verify handles missing optional fields (no TODOs, no project files)

### Integration tests (`Tests/c.Integration.Tests.ps1`)

- Meta-query input with mocked git -> synthetic XML output
- Verify `$metricMode = 'meta-query'` in metrics
- Verify refiner and compiler NOT called (0 ollama invocations)
- Verify `-MetaQuery` flag forces path on non-meta input

## File changes summary

| File | Change |
|------|--------|
| `cprompt.psm1` | Add `Test-InputIsMetaQuery`, `Get-ProjectContext`, `Format-MetaQueryXml`. Export all three. |
| `c.ps1` | Add `-MetaQuery` param. Add meta-query stage between pregate and refiner. Add `contextGatherMs` to metrics. |
| `hooks/c-autorefine.ps1` | Delete lines 51-54 (meta-question regex). No other changes. |
| `Tests/cprompt.Tests.ps1` | Add unit tests for 3 new functions. |
| `Tests/c.Integration.Tests.ps1` | Add meta-query integration tests. |
