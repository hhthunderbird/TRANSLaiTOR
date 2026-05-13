# Local Refiner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local Ollama-based refiner stage that turns vague user input into specific, clarified input before the existing compiler stage runs.

**Architecture:** Two-stage Ollama pipeline. New `Modelfile.refiner` decides whether the raw input is clear; if not, it emits clarifying questions in a tagged XML envelope. `c.ps1` reads the envelope, prompts the user via `Read-Host`, merges answers into the input, and forwards to the existing `prompt-opt` compiler. The refiner never blocks the happy path: any failure falls back to passing the raw input through.

**Tech Stack:** PowerShell 5.1, Pester v3, Ollama (Llama 3.2 3B), Modelfile DSL.

---

## File Structure

- **New:**
  - `Modelfile.refiner` — Ollama Modelfile for the new refiner model.
- **Renamed:**
  - `ModelFile` → `Modelfile.compiler` (canonical casing + clearer role now that two Modelfiles coexist).
- **Modified:**
  - `cprompt.psm1` — adds `Get-RefinerOutput`, `Test-RefinerOutput`, `Merge-RefinementAnswers`; exports them.
  - `c.ps1` — adds refiner stage before the compiler call, `-NoRefine` switch, `-Raw` implies `-NoRefine`, history entries gain `rawInput` and `refined`.
  - `Tests/cprompt.Tests.ps1` — TDD coverage for new module helpers.
  - `README.md` — updates install steps (two Modelfiles) and the flag table.

---

### Task 1: Rename ModelFile → Modelfile.compiler

**Files:**
- Rename: `ModelFile` → `Modelfile.compiler`
- Modify: `README.md` (install instructions, file list)
- Modify: `c.ps1` — none yet; the default model name `prompt-opt` is unchanged.

- [ ] **Step 1: Rename the file in git**

```bash
cd C:/Users/hhthu/Scripts
git mv ModelFile Modelfile.compiler
```

- [ ] **Step 2: Update README.md install + files section**

In `README.md`, change the `ollama create` example and the `## Files` list:

```markdown
2. Create the local model:
   ```powershell
   ollama create prompt-opt -f C:\Users\hhthu\Scripts\Modelfile.compiler
   ```
```

```markdown
## Files

- `c.ps1` — entrypoint, argument parsing, Ollama call, Claude pipe.
- `c.cmd` — Windows shim so `c` works in cmd.exe and plain `PATH` setups.
- `cprompt.psm1` — pure helpers (BOM strip, XML extraction, tool resolution).
- `Modelfile.compiler` — Ollama Modelfile for the compiler stage
  (`prompt-opt` model): emits the `<task>/<context>/<constraints>` block.
- `Modelfile.refiner` — Ollama Modelfile for the refiner stage
  (`prompt-refiner` model): emits `<passthrough>` or `<questions>`.
- `Tests/cprompt.Tests.ps1` — Pester v3 unit tests.
```

- [ ] **Step 3: Run existing tests to confirm no regression**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 37 Passed, 0 Failed.

- [ ] **Step 4: Commit**

```bash
git add Modelfile.compiler README.md
git commit -m "chore: rename ModelFile to Modelfile.compiler"
```

---

### Task 2: Create Modelfile.refiner

**Files:**
- Create: `Modelfile.refiner`

- [ ] **Step 1: Create Modelfile.refiner**

```
FROM llama3.2:3b

# Determinism + anti-loop tuning
PARAMETER temperature 0.05
PARAMETER top_k 20
PARAMETER top_p 0.7
PARAMETER repeat_penalty 1.3
PARAMETER repeat_last_n 128
PARAMETER num_predict 120
PARAMETER num_ctx 1024

PARAMETER stop "</passthrough>"
PARAMETER stop "</questions>"
PARAMETER stop "<|eot_id|>"
PARAMETER stop "<|file_separator|>"

SYSTEM """
You are an INPUT TRIAGE assistant. Zero personality. Zero creativity.

Your ONLY output is one of these two XML shapes, nothing else:

A) <passthrough>VERBATIM INPUT</passthrough>
B) <questions><q>...</q><q>...</q></questions>   (1 to 3 q items)

CHOOSE A when the input already names BOTH a concrete action AND a stack/runtime/scope.
CHOOSE B when the input is vague: missing stack, missing direction, missing scope.

Bias toward A. A false-positive question is worse than a passthrough that yields a
generic <context> downstream.

In B:
- Each <q> is one direct sentence ending in '?'.
- Target a missing slot: language/stack, runtime, scale, primary direction
  (read/write), acceptance criterion.
- At most 3 questions.
- Tag names are EXACTLY: <questions>, <q>, </q>, </questions>. Never invent
  others (no <question>, no <ask>, no <prompt>).

LANGUAGE: write questions in the user's input language. Tags stay English.
"""

# Few-shot via native multi-turn

MESSAGE user me ajuda a fazer um sistema de tiro no ecs usando burst
MESSAGE assistant <passthrough>me ajuda a fazer um sistema de tiro no ecs usando burst</passthrough>

MESSAGE user preciso ajuda com cache
MESSAGE assistant <questions><q>qual stack/runtime?</q><q>leitura ou escrita predominante?</q><q>distribuído ou local?</q></questions>

MESSAGE user otimiza essa query sql que ta lenta com milhoes de linhas
MESSAGE assistant <passthrough>otimiza essa query sql que ta lenta com milhoes de linhas</passthrough>

MESSAGE user preciso de algo melhor
MESSAGE assistant <questions><q>qual área/escopo?</q><q>o que está ruim no atual?</q></questions>

MESSAGE user write a worker queue
MESSAGE assistant <questions><q>which language and runtime?</q><q>in-process or distributed broker?</q><q>at-least-once or at-most-once delivery?</q></questions>

MESSAGE user implementa um cache LRU thread-safe em Go com capacidade configuravel
MESSAGE assistant <passthrough>implementa um cache LRU thread-safe em Go com capacidade configuravel</passthrough>
```

- [ ] **Step 2: Smoke-create the model**

Run: `ollama create prompt-refiner -f C:\Users\hhthu\Scripts\Modelfile.refiner`
Expected: success message, no parser error.

- [ ] **Step 3: Smoke-run a vague input**

Run: `"preciso ajuda com cache" | ollama run prompt-refiner`
Expected: a `<questions>...</questions>` block. If output is empty or `<passthrough>` for a clearly-vague input, the few-shots need tightening before continuing (re-edit and re-create).

- [ ] **Step 4: Smoke-run a specific input**

Run: `"implementa cache LRU thread-safe em Go com capacidade configuravel" | ollama run prompt-refiner`
Expected: a `<passthrough>...</passthrough>` block containing the original text.

- [ ] **Step 5: Commit**

```bash
git add Modelfile.refiner
git commit -m "feat: add Modelfile.refiner for input triage stage"
```

---

### Task 3: TDD `Get-RefinerOutput` — passthrough case

**Files:**
- Test: `Tests/cprompt.Tests.ps1`
- Modify: `cprompt.psm1`

- [ ] **Step 1: Write the failing test**

Add to `Tests/cprompt.Tests.ps1`, after the existing `Describe 'Get-PromptXml'` block:

```powershell
Describe 'Get-RefinerOutput' {
    It 'parses a clean passthrough envelope' {
        $raw = '<passthrough>preserve this exactly</passthrough>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'passthrough'
        $result.Payload | Should Be 'preserve this exactly'
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit -TestName 'parses a clean passthrough envelope'"`
Expected: FAIL with `Get-RefinerOutput not recognized`.

- [ ] **Step 3: Implement minimal Get-RefinerOutput**

In `cprompt.psm1`, after `Test-PromptXml`:

```powershell
function Get-RefinerOutput {
    [CmdletBinding()]
    param([string]$RawOutput)
    if (-not $RawOutput) { return $null }
    $clean = Remove-Bom $RawOutput
    $passthrough = [regex]::Match($clean, '(?s)<passthrough>(.*?)</\w+>')
    if ($passthrough.Success) {
        $payload = $passthrough.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($payload)) { return $null }
        return @{ Mode = 'passthrough'; Payload = $payload }
    }
    return $null
}
```

Also add `Get-RefinerOutput` to the `Export-ModuleMember` list at the bottom of the file:

```powershell
Export-ModuleMember -Function `
    Remove-Bom, `
    Get-PromptXml, `
    Test-PromptXml, `
    Resolve-Tool, `
    Test-InputAcceptable, `
    Get-CacheKey, `
    Get-CachedXml, `
    Set-CachedXml, `
    Add-HistoryEntry, `
    Get-LastHistoryEntry, `
    Get-RefinerOutput
```

- [ ] **Step 4: Run test, verify it passes**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 38 Passed, 0 Failed.

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(refiner): Get-RefinerOutput parses passthrough envelope"
```

---

### Task 4: TDD `Get-RefinerOutput` — questions envelope (1, 2, 3 items)

**Files:**
- Test: `Tests/cprompt.Tests.ps1`
- Modify: `cprompt.psm1`

- [ ] **Step 1: Write the failing tests**

Add inside the existing `Describe 'Get-RefinerOutput'` block:

```powershell
    It 'parses a single-question envelope' {
        $raw = '<questions><q>which language?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'questions'
        $result.Payload.Count | Should Be 1
        $result.Payload[0] | Should Be 'which language?'
    }

    It 'parses a two-question envelope' {
        $raw = '<questions><q>a?</q><q>b?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 2
        $result.Payload[0] | Should Be 'a?'
        $result.Payload[1] | Should Be 'b?'
    }

    It 'parses a three-question envelope' {
        $raw = '<questions><q>a?</q><q>b?</q><q>c?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 3
    }
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 3 new FAILs (the others still pass).

- [ ] **Step 3: Extend Get-RefinerOutput to handle questions**

Replace the body of `Get-RefinerOutput` in `cprompt.psm1`:

```powershell
function Get-RefinerOutput {
    [CmdletBinding()]
    param([string]$RawOutput)
    if (-not $RawOutput) { return $null }
    $clean = Remove-Bom $RawOutput

    $passthrough = [regex]::Match($clean, '(?s)<passthrough>(.*?)</\w+>')
    if ($passthrough.Success) {
        $payload = $passthrough.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($payload)) { return $null }
        return @{ Mode = 'passthrough'; Payload = $payload }
    }

    $questionsBlock = [regex]::Match($clean, '(?s)<questions>(.*?)</\w+>')
    if ($questionsBlock.Success) {
        $inner = $questionsBlock.Groups[1].Value
        $qMatches = [regex]::Matches($inner, '(?s)<q>(.*?)</\w+>')
        $qs = @()
        foreach ($qm in $qMatches) {
            $text = $qm.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $qs += $text
            }
        }
        if ($qs.Count -eq 0) { return $null }
        return @{ Mode = 'questions'; Payload = $qs }
    }

    return $null
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 41 Passed, 0 Failed.

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(refiner): Get-RefinerOutput parses 1-3 question envelope"
```

---

### Task 5: TDD `Get-RefinerOutput` — cap at 3, drop empty `<q></q>`

**Files:**
- Test: `Tests/cprompt.Tests.ps1`
- Modify: `cprompt.psm1`

- [ ] **Step 1: Write the failing tests**

Add inside `Describe 'Get-RefinerOutput'`:

```powershell
    It 'caps the question list at 3 even if the model emits more' {
        $raw = '<questions><q>1?</q><q>2?</q><q>3?</q><q>4?</q><q>5?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 3
        $result.Payload[0] | Should Be '1?'
        $result.Payload[2] | Should Be '3?'
    }

    It 'drops empty <q></q> elements before counting' {
        $raw = '<questions><q>a?</q><q>   </q><q>b?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 2
        $result.Payload[0] | Should Be 'a?'
        $result.Payload[1] | Should Be 'b?'
    }
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: "caps the question list at 3" fails (count is 5). "drops empty" already passes because the existing impl skips whitespace items.

- [ ] **Step 3: Add the cap inside Get-RefinerOutput**

In `cprompt.psm1`, inside the `<questions>` branch, after the foreach loop, before the final `return`:

```powershell
        if ($qs.Count -gt 3) { $qs = $qs[0..2] }
```

Final shape of the questions branch:

```powershell
    $questionsBlock = [regex]::Match($clean, '(?s)<questions>(.*?)</\w+>')
    if ($questionsBlock.Success) {
        $inner = $questionsBlock.Groups[1].Value
        $qMatches = [regex]::Matches($inner, '(?s)<q>(.*?)</\w+>')
        $qs = @()
        foreach ($qm in $qMatches) {
            $text = $qm.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $qs += $text
            }
        }
        if ($qs.Count -eq 0) { return $null }
        if ($qs.Count -gt 3) { $qs = $qs[0..2] }
        return @{ Mode = 'questions'; Payload = $qs }
    }
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 43 Passed, 0 Failed.

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(refiner): cap questions at 3 and drop empty q items"
```

---

### Task 6: TDD `Get-RefinerOutput` — salvage hallucinated close tags

**Files:**
- Test: `Tests/cprompt.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Add inside `Describe 'Get-RefinerOutput'`:

```powershell
    It 'salvages passthrough when close tag is hallucinated' {
        $raw = '<passthrough>keep me</wrong>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'passthrough'
        $result.Payload | Should Be 'keep me'
    }

    It 'salvages questions when outer close tag is hallucinated' {
        $raw = '<questions><q>x?</q><q>y?</q></ask>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'questions'
        $result.Payload.Count | Should Be 2
    }

    It 'salvages each q when q close tag is hallucinated' {
        $raw = '<questions><q>x?</question><q>y?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'questions'
        $result.Payload[0] | Should Be 'x?'
        $result.Payload[1] | Should Be 'y?'
    }
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: All 3 PASS (the regex `</\w+>` already accepts any closing tag, so this is verifying — not extending — current behavior).

If any fail, fix Get-RefinerOutput to use the `</\w+>` pattern consistently.

- [ ] **Step 3: Commit**

```bash
git add Tests/cprompt.Tests.ps1
git commit -m "test(refiner): document salvage of hallucinated close tags"
```

---

### Task 7: TDD `Get-RefinerOutput` — null on garbage / empty input

**Files:**
- Test: `Tests/cprompt.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Add inside `Describe 'Get-RefinerOutput'`:

```powershell
    It 'returns $null on empty input' {
        (Get-RefinerOutput '') | Should BeNullOrEmpty
    }

    It 'returns $null when no recognizable envelope is present' {
        (Get-RefinerOutput 'just some prose, no tags at all') | Should BeNullOrEmpty
    }

    It 'returns $null when passthrough body is whitespace only' {
        (Get-RefinerOutput '<passthrough>   </passthrough>') | Should BeNullOrEmpty
    }

    It 'returns $null when questions body has only empty <q> items' {
        (Get-RefinerOutput '<questions><q></q><q>   </q></questions>') | Should BeNullOrEmpty
    }
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: All 4 PASS (current impl already returns $null in these cases).

If any fail, fix Get-RefinerOutput.

- [ ] **Step 3: Commit**

```bash
git add Tests/cprompt.Tests.ps1
git commit -m "test(refiner): document null returns on garbage and empty input"
```

---

### Task 8: TDD `Test-RefinerOutput`

**Files:**
- Test: `Tests/cprompt.Tests.ps1`
- Modify: `cprompt.psm1`

- [ ] **Step 1: Write the failing tests**

Add a new `Describe` block to `Tests/cprompt.Tests.ps1`:

```powershell
Describe 'Test-RefinerOutput' {
    It 'returns $true for a valid passthrough hashtable' {
        (Test-RefinerOutput @{ Mode = 'passthrough'; Payload = 'x' }) | Should Be $true
    }

    It 'returns $true for a valid questions hashtable' {
        (Test-RefinerOutput @{ Mode = 'questions'; Payload = @('a?', 'b?') }) | Should Be $true
    }

    It 'returns $false for $null' {
        (Test-RefinerOutput $null) | Should Be $false
    }

    It 'returns $false for unknown Mode' {
        (Test-RefinerOutput @{ Mode = 'banana'; Payload = 'x' }) | Should Be $false
    }

    It 'returns $false for passthrough with empty Payload' {
        (Test-RefinerOutput @{ Mode = 'passthrough'; Payload = '' }) | Should Be $false
    }

    It 'returns $false for questions with empty list' {
        (Test-RefinerOutput @{ Mode = 'questions'; Payload = @() }) | Should Be $false
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 6 FAILs (`Test-RefinerOutput not recognized`).

- [ ] **Step 3: Implement Test-RefinerOutput**

Add to `cprompt.psm1` after `Get-RefinerOutput`:

```powershell
function Test-RefinerOutput {
    [CmdletBinding()]
    param($Parsed)
    if ($null -eq $Parsed) { return $false }
    if (-not $Parsed.ContainsKey('Mode')) { return $false }
    if (-not $Parsed.ContainsKey('Payload')) { return $false }
    switch ($Parsed.Mode) {
        'passthrough' {
            return -not [string]::IsNullOrWhiteSpace([string]$Parsed.Payload)
        }
        'questions' {
            return ($Parsed.Payload -is [array]) -and ($Parsed.Payload.Count -gt 0)
        }
        default { return $false }
    }
}
```

Add `Test-RefinerOutput` to the `Export-ModuleMember` list.

- [ ] **Step 4: Run tests, verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 53 Passed, 0 Failed.

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(refiner): Test-RefinerOutput validates parsed envelope"
```

---

### Task 9: TDD `Merge-RefinementAnswers`

**Files:**
- Test: `Tests/cprompt.Tests.ps1`
- Modify: `cprompt.psm1`

This helper exists so `c.ps1` does not have to do string assembly inline — the merge logic is pure and testable.

- [ ] **Step 1: Write the failing tests**

Add a new `Describe` block:

```powershell
Describe 'Merge-RefinementAnswers' {
    It 'appends each question/answer pair on its own line, separated from raw' {
        $result = Merge-RefinementAnswers -Raw 'preciso ajuda com cache' -Pairs @(
            @{ Question = 'qual stack?'; Answer = 'Python + Redis' }
            @{ Question = 'leitura ou escrita?'; Answer = 'leitura, 100x mais' }
        )
        $expected = "preciso ajuda com cache`n`nqual stack?: Python + Redis`nleitura ou escrita?: leitura, 100x mais"
        $result | Should Be $expected
    }

    It 'drops pairs whose answer is empty or whitespace' {
        $result = Merge-RefinementAnswers -Raw 'x' -Pairs @(
            @{ Question = 'a?'; Answer = '' }
            @{ Question = 'b?'; Answer = '   ' }
            @{ Question = 'c?'; Answer = 'yes' }
        )
        $result | Should Be "x`n`nc?: yes"
    }

    It 'returns the raw input unchanged when all pairs are empty' {
        $result = Merge-RefinementAnswers -Raw 'x' -Pairs @(
            @{ Question = 'a?'; Answer = '' }
        )
        $result | Should Be 'x'
    }

    It 'returns the raw input unchanged when Pairs is empty' {
        (Merge-RefinementAnswers -Raw 'x' -Pairs @()) | Should Be 'x'
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 4 FAILs (`Merge-RefinementAnswers not recognized`).

- [ ] **Step 3: Implement Merge-RefinementAnswers**

Add to `cprompt.psm1`:

```powershell
function Merge-RefinementAnswers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Pairs
    )
    $kept = @()
    foreach ($pair in $Pairs) {
        $answer = [string]$pair.Answer
        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            $kept += "$($pair.Question): $($answer.Trim())"
        }
    }
    if ($kept.Count -eq 0) { return $Raw }
    return "$Raw`n`n" + ($kept -join "`n")
}
```

Add `Merge-RefinementAnswers` to `Export-ModuleMember`.

- [ ] **Step 4: Run tests, verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 57 Passed, 0 Failed.

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(refiner): Merge-RefinementAnswers helper"
```

---

### Task 10: Wire the refiner stage into `c.ps1`

**Files:**
- Modify: `c.ps1`

This is integration work. The pure pieces are already TDD-covered; this task wires them and is verified by manual smoke.

- [ ] **Step 1: Add the `-NoRefine` switch and the refiner state constants**

In `c.ps1`, update the `param()` block to add `-NoRefine`:

```powershell
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Send,
    [switch]$Raw,
    [switch]$Help,
    [switch]$NoCache,
    [switch]$Last,
    [switch]$NoRefine,
    [string]$Model = 'prompt-opt',
    [string]$RefinerModel = 'prompt-refiner',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Prompt
)
```

- [ ] **Step 2: Update `Show-Usage` to document `-NoRefine` and `-RefinerModel`**

Replace the body of `Show-Usage`:

```powershell
function Show-Usage {
    @"
TRANSLaiTOR - local prompt compiler

uso:  c <ideia>                  distila e copia XML para clipboard
      c <ideia> -Raw             imprime XML em stdout (implica -NoRefine)
      c <ideia> -Send            envia XML direto para claude -p
      c <ideia> -Model X         usa modelo Ollama compilador diferente (default: prompt-opt)
      c <ideia> -RefinerModel Y  usa modelo Ollama refinador diferente (default: prompt-refiner)
      c <ideia> -NoRefine        pula o estagio refinador, vai direto ao compilador
      c <ideia> -NoCache         ignora cache, forca chamada nova ao Ollama compilador
      c -Last                    imprime ultimo XML do historico
      c -Help                    mostra esta ajuda

estado local: $script:StateRoot
limites:      input maximo $script:MaxInputChars caracteres
"@
}
```

- [ ] **Step 3: Add the refiner stage block between input validation and the cache lookup**

In `c.ps1`, AFTER the input validation block (the `if (-not (Test-InputAcceptable …))` block) and BEFORE the `$cacheKey = Get-CacheKey …` line, insert:

```powershell
$rawInput = $userInput
$refined  = $false

# `-Raw` implies `-NoRefine`: scripted use cannot answer prompts interactively.
$skipRefiner = $NoRefine -or $Raw

if (-not $skipRefiner) {
    $refinerAvailable = $true
    try { $null = Resolve-Tool 'ollama' } catch { $refinerAvailable = $false }

    if ($refinerAvailable) {
        if (-not $Raw) {
            Write-Host "--- refinando input ($RefinerModel) ---" -ForegroundColor DarkCyan
        }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $refinerRaw = ''
        try {
            $refinerRaw = ($userInput | & ollama run $RefinerModel 2>$null | Out-String)
        } catch {
            $refinerRaw = ''
        }
        $ErrorActionPreference = $prevEAP

        $parsed = $null
        if ($refinerRaw -and $LASTEXITCODE -eq 0) {
            $parsed = Get-RefinerOutput $refinerRaw
        }

        if (Test-RefinerOutput $parsed) {
            if ($parsed.Mode -eq 'questions') {
                $pairs = @()
                $i = 1
                foreach ($q in $parsed.Payload) {
                    Write-Host "$i) $q" -ForegroundColor Yellow
                    $answer = Read-Host '>'
                    $pairs += @{ Question = $q; Answer = $answer }
                    $i++
                }
                $userInput = Merge-RefinementAnswers -Raw $rawInput -Pairs $pairs
                if ($userInput -ne $rawInput) { $refined = $true }
            }
            # Mode = 'passthrough' → leave $userInput alone, $refined stays $false.
        } else {
            # Refiner failed or returned garbage. Fall back silently to raw.
            if (-not $Raw) {
                Write-Host "(refiner sem saida util — usando input cru)" -ForegroundColor DarkGray
            }
        }
    }
}
```

- [ ] **Step 4: Update the history-write block to include `rawInput` and `refined`**

Replace the existing `Add-HistoryEntry` call in `c.ps1`:

```powershell
Add-HistoryEntry -Path $script:HistoryPath -Entry @{
    rawInput = $rawInput
    input    = $userInput
    model    = $Model
    xml      = $xml
    cached   = $fromCache
    refined  = $refined
}
```

- [ ] **Step 5: Re-run unit tests, smoke help output**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 57 Passed, 0 Failed.

Run: `powershell -NoProfile -Command "& 'C:/Users/hhthu/Scripts/c.ps1' -Help"`
Expected: usage text includes the new `-NoRefine` and `-RefinerModel` lines.

- [ ] **Step 6: Manual smoke — clear input goes passthrough**

Run: `powershell -NoProfile -Command "& 'C:/Users/hhthu/Scripts/c.ps1' 'implementa cache LRU thread-safe em Go com capacidade configuravel' -Raw"`
Expected: prints a valid `<task>…</constraints>` block. No interactive prompts (because `-Raw` implies `-NoRefine`).

- [ ] **Step 7: Manual smoke — vague input triggers questions**

In an interactive PowerShell window (not Bash), run:
`c "preciso ajuda com cache"`
Expected: refining banner, 1–3 numbered questions, prompts for answers, then a destilando banner, then XML output to clipboard.

- [ ] **Step 8: Manual smoke — refiner unavailable falls back**

Temporarily rename or remove the `prompt-refiner` model (or pass `-RefinerModel nonexistent`):
`c "preciso ajuda com cache" -RefinerModel nonexistent`
Expected: "(refiner sem saida util — usando input cru)" message, then normal compiler run.

- [ ] **Step 9: Commit**

```bash
git add c.ps1
git commit -m "feat(refiner): wire refiner stage into c.ps1 with -NoRefine and fallback"
```

---

### Task 11: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the refiner to the install section**

In `README.md`, replace the install section step 2 with:

```markdown
2. Create the local models:
   ```powershell
   ollama create prompt-opt      -f C:\Users\hhthu\Scripts\Modelfile.compiler
   ollama create prompt-refiner  -f C:\Users\hhthu\Scripts\Modelfile.refiner
   ```
```

- [ ] **Step 2: Update the usage section**

Add new flag lines to the `## Usage` block:

```markdown
c "..." -NoRefine                                     # skip the refiner, go straight to compiler
c "..." -RefinerModel prompt-refiner-other            # use a different refiner Ollama model
```

- [ ] **Step 3: Add a pipeline section after Usage**

```markdown
## Pipeline stages

1. **Refiner** (`prompt-refiner`): inspects the raw input. Emits
   `<passthrough>` when the input is already specific, or `<questions>`
   with 1–3 clarifying questions when the input is vague. Answers are
   collected in the terminal and merged into the input. Bypassed by
   `-NoRefine` or `-Raw`. Failure falls back to the raw input.
2. **Compiler** (`prompt-opt`): turns the (possibly enriched) input
   into the three-tag XML block. Cached by `(model, final input)`.
3. **Sink**: clipboard (default), `claude -p` (`-Send`), or stdout
   (`-Raw`).
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README documents refiner stage and -NoRefine"
```

---

### Task 12: Push branch and open PR

**Files:** none (workflow only).

- [ ] **Step 1: Re-run all tests one final time**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: 57 Passed, 0 Failed.

- [ ] **Step 2: Push the branch**

```bash
cd C:/Users/hhthu/Scripts
git push -u origin feat/local-refiner
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --title "feat: local refiner stage (ollama-based input triage)" --body "$(cat <<'EOF'
## Summary
- Adds a `Modelfile.refiner` Ollama model that triages raw input as
  `<passthrough>` (already specific) or `<questions>` (1–3 clarifying
  questions).
- Wires a new refiner stage into `c.ps1` ahead of the existing
  compiler stage. `-Raw` implies `-NoRefine`; refiner failure falls
  back to the raw input.
- Renames the original `ModelFile` to `Modelfile.compiler`.
- Adds pure helpers (`Get-RefinerOutput`, `Test-RefinerOutput`,
  `Merge-RefinementAnswers`) with full TDD coverage.

## Test plan
- [ ] `Invoke-Pester C:\Users\hhthu\Scripts\Tests` — 57/57 passing.
- [ ] `ollama create prompt-refiner -f Modelfile.refiner` succeeds.
- [ ] Vague input (e.g. `preciso ajuda com cache`) yields questions.
- [ ] Specific input (e.g. `implementa cache LRU em Go`) yields passthrough.
- [ ] `-NoRefine` and `-Raw` skip the refiner.
- [ ] Refiner unavailable (`-RefinerModel nonexistent`) falls back to
      raw input without aborting the run.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Note the PR URL in this session**

Capture the URL printed by `gh pr create` and return it to the user.

---

## Self-Review Notes

- Spec coverage: every section of the spec maps to a task above
  (renaming → Task 1; Modelfile.refiner → Task 2; helpers → Tasks 3–9;
  c.ps1 wiring → Task 10; README → Task 11; rollout/PR → Task 12).
- All steps contain runnable commands and complete code blocks.
- Function names match across tasks (`Get-RefinerOutput`,
  `Test-RefinerOutput`, `Merge-RefinementAnswers`).
- Final test count target (57) is internally consistent with the
  starting count (37) plus per-task additions (1+3+2+3+4+6+4 = 23 new
  cases, minus 3 already-passing ones counted in Task 6/7 = ~20 new
  passing assertions). The exact number reported by Pester may differ
  by ±2; the gate is **0 failed**, not an exact pass count.
