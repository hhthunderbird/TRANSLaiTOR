# Meta-Query Detection + Context Injection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect status/meta questions in the TRANSLaiTOR pipeline, gather project context (git state, TODOs, project files), and output synthetic XML — skipping the refiner and compiler entirely.

**Architecture:** Three new functions in `cprompt.psm1` (detection, gathering, formatting). A new pipeline stage in `c.ps1` between input validation and the pregate. The autorefine hook delegates meta-question handling to `c.ps1` instead of silently dropping them.

**Tech Stack:** PowerShell 5.1, Pester 5, git CLI, existing `cprompt.psm1` module and `c.ps1` pipeline.

---

## File Structure

| File | Role |
|------|------|
| `cprompt.psm1` | Add `Test-InputIsMetaQuery`, `Get-ProjectContext`, `Format-MetaQueryXml`. Update `Export-ModuleMember`. |
| `c.ps1` | Add `-MetaQuery` switch param. Add meta-query stage before pregate. Add `contextGatherMs` to metrics. |
| `hooks/c-autorefine.ps1` | Delete lines 51-54 (meta-question regex + exit). Update comment block. |
| `Tests/cprompt.Tests.ps1` | Add unit tests for all 3 new functions. |
| `Tests/c.Integration.Tests.ps1` | Add meta-query integration tests. |

---

### Task 1: `Test-InputIsMetaQuery` — failing tests

**Files:**
- Test: `Tests/cprompt.Tests.ps1` (append after `Test-InputIsZeroSignal` Describe block, around line 701)

- [ ] **Step 1: Write failing tests for `Test-InputIsMetaQuery`**

Append this Describe block after the `Test-InputIsZeroSignal` block (line 701) in `Tests/cprompt.Tests.ps1`:

```powershell
Describe 'Test-InputIsMetaQuery' {
    # True positives — meta/status queries with WH-word + state marker
    It 'detects PT-BR status query with agora' {
        (Test-InputIsMetaQuery -Text 'o que temos para fazer agora?') | Should -Be $true
    }

    It 'detects EN query with left' {
        (Test-InputIsMetaQuery -Text "what's left to do?") | Should -Be $true
    }

    It 'detects PT-BR query with falta' {
        (Test-InputIsMetaQuery -Text 'o que falta?') | Should -Be $true
    }

    It 'detects PT-BR query with proximo (no accent)' {
        (Test-InputIsMetaQuery -Text 'qual o proximo passo?') | Should -Be $true
    }

    It 'detects PT-BR query with próximo (accented)' {
        (Test-InputIsMetaQuery -Text 'qual o próximo passo?') | Should -Be $true
    }

    It 'detects EN query with now' {
        (Test-InputIsMetaQuery -Text 'where are we now?') | Should -Be $true
    }

    It 'detects EN query with current status' {
        (Test-InputIsMetaQuery -Text 'what is the current status?') | Should -Be $true
    }

    It 'detects EN query with remaining' {
        (Test-InputIsMetaQuery -Text 'what work is remaining?') | Should -Be $true
    }

    It 'detects PT-BR query with pendente' {
        (Test-InputIsMetaQuery -Text 'o que esta pendente?') | Should -Be $true
    }

    # True negatives — coding questions (WH-word but no state marker)
    It 'rejects coding question about cache in Go' {
        (Test-InputIsMetaQuery -Text 'como faco cache LRU em Go?') | Should -Be $false
    }

    It 'rejects EN coding question about error handling' {
        (Test-InputIsMetaQuery -Text "what's the best way to handle errors?") | Should -Be $false
    }

    It 'rejects EN coding question about REST endpoint' {
        (Test-InputIsMetaQuery -Text 'how do I create a REST endpoint?') | Should -Be $false
    }

    It 'rejects PT-BR coding question about testing lib' {
        (Test-InputIsMetaQuery -Text 'qual a melhor lib para testes?') | Should -Be $false
    }

    It 'rejects EN coding question about slow query' {
        (Test-InputIsMetaQuery -Text 'why is this query slow?') | Should -Be $false
    }

    # Edge cases
    It 'returns $false for null' {
        (Test-InputIsMetaQuery -Text $null) | Should -Be $false
    }

    It 'returns $false for empty string' {
        (Test-InputIsMetaQuery -Text '') | Should -Be $false
    }

    It 'returns $false for whitespace' {
        (Test-InputIsMetaQuery -Text '   ') | Should -Be $false
    }

    It 'returns $false when no question mark at end' {
        (Test-InputIsMetaQuery -Text 'o que temos para fazer agora') | Should -Be $false
    }

    It 'returns $false for state marker without WH-word' {
        (Test-InputIsMetaQuery -Text 'mostra o status agora?') | Should -Be $false
    }

    It 'is case insensitive' {
        (Test-InputIsMetaQuery -Text 'O QUE FALTA?') | Should -Be $true
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Filter @{FullName='*Test-InputIsMetaQuery*'} -Output Detailed"`
Expected: All tests FAIL with `"The term 'Test-InputIsMetaQuery' is not recognized"`

- [ ] **Step 3: Commit failing tests**

```bash
git add Tests/cprompt.Tests.ps1
git commit -m "test(meta-query): add failing tests for Test-InputIsMetaQuery"
```

---

### Task 2: `Test-InputIsMetaQuery` — implementation

**Files:**
- Modify: `cprompt.psm1:500` (after `Test-InputIsZeroSignal` function)
- Modify: `cprompt.psm1:640-664` (Export-ModuleMember list)

- [ ] **Step 1: Implement `Test-InputIsMetaQuery` in `cprompt.psm1`**

Add this function after `Test-InputIsZeroSignal` (after line 500):

```powershell
function Test-InputIsMetaQuery {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $whWord      = '(qual|que|o que|por que|como|quando|onde|what|why|how|when|where|which|who|whose)'
    $stateMarker = '(agora|falta|pr[oó]ximo|pendente|restante|now|left|next|current|todo|remaining|status|progress)'
    $pattern     = "(?i)^\s*$whWord\b.*\b$stateMarker\b.*\?\s*$"
    return [bool]($Text -match $pattern)
}
```

- [ ] **Step 2: Add `Test-InputIsMetaQuery` to `Export-ModuleMember`**

In `cprompt.psm1`, add `Test-InputIsMetaQuery` to the `Export-ModuleMember` list. After the `Test-InputIsZeroSignal, `` ` line, add:

```powershell
    Test-InputIsMetaQuery, `
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Filter @{FullName='*Test-InputIsMetaQuery*'} -Output Detailed"`
Expected: All 21 tests PASS

- [ ] **Step 4: Commit**

```bash
git add cprompt.psm1
git commit -m "feat(meta-query): implement Test-InputIsMetaQuery detection"
```

---

### Task 3: `Format-MetaQueryXml` — failing tests

**Files:**
- Test: `Tests/cprompt.Tests.ps1` (append after `Test-InputIsMetaQuery` Describe block)

- [ ] **Step 1: Write failing tests for `Format-MetaQueryXml`**

Append after the `Test-InputIsMetaQuery` Describe block:

```powershell
Describe 'Format-MetaQueryXml' {
    BeforeAll {
        $script:hookEnvelope = '(?s)<task>\s*\S.*?\s*</task>\s*<context>\s*\S.*?\s*</context>\s*<constraints>\s*\S.*?\s*</constraints>'
    }

    It 'produces valid XML envelope matching hook regex' {
        $ctx = @{
            Branch       = 'main'
            Status       = '?? newfile.cs'
            Log          = 'abc1234 fix auth'
            Todos        = 'src/foo.cs:42: // TODO fix this'
            ProjectFiles = @{ 'CLAUDE.md' = 'project instructions' }
            ElapsedMs    = 500
        }
        $xml = Format-MetaQueryXml -Question 'o que falta?' -Context $ctx
        $xml | Should -Match $script:hookEnvelope
    }

    It 'includes branch in context tag' {
        $ctx = @{
            Branch       = 'feat/cool'
            Status       = ''
            Log          = ''
            Todos        = $null
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'what is left?' -Context $ctx
        $xml | Should -Match 'feat/cool'
    }

    It 'includes git status in context tag' {
        $ctx = @{
            Branch       = 'main'
            Status       = 'M  src/app.ps1'
            Log          = ''
            Todos        = $null
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'o que falta?' -Context $ctx
        $xml | Should -Match 'src/app.ps1'
    }

    It 'includes git log in context tag' {
        $ctx = @{
            Branch       = 'main'
            Status       = ''
            Log          = "abc1234 first commit`ndef5678 second commit"
            Todos        = $null
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'what next?' -Context $ctx
        $xml | Should -Match 'abc1234 first commit'
    }

    It 'includes TODOs when present' {
        $ctx = @{
            Branch       = 'main'
            Status       = ''
            Log          = ''
            Todos        = 'file.ps1:10: # TODO fix'
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'o que falta?' -Context $ctx
        $xml | Should -Match 'TODO fix'
    }

    It 'handles null TODOs gracefully' {
        $ctx = @{
            Branch       = 'main'
            Status       = ''
            Log          = ''
            Todos        = $null
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'what is left?' -Context $ctx
        $xml | Should -Match $script:hookEnvelope
        $xml | Should -Not -Match 'TODOs:'
    }

    It 'handles empty ProjectFiles gracefully' {
        $ctx = @{
            Branch       = 'main'
            Status       = ''
            Log          = ''
            Todos        = $null
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'status?' -Context $ctx
        $xml | Should -Match $script:hookEnvelope
    }

    It 'lists present project file names' {
        $ctx = @{
            Branch       = 'main'
            Status       = ''
            Log          = ''
            Todos        = $null
            ProjectFiles = @{ 'CLAUDE.md' = 'content'; 'README.md' = 'readme' }
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'status?' -Context $ctx
        $xml | Should -Match 'CLAUDE\.md'
        $xml | Should -Match 'README\.md'
    }

    It 'includes the original question in constraints tag' {
        $ctx = @{
            Branch       = 'main'
            Status       = ''
            Log          = ''
            Todos        = $null
            ProjectFiles = @{}
            ElapsedMs    = 100
        }
        $xml = Format-MetaQueryXml -Question 'o que temos para fazer agora?' -Context $ctx
        $xml | Should -Match 'o que temos para fazer agora\?'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Filter @{FullName='*Format-MetaQueryXml*'} -Output Detailed"`
Expected: All tests FAIL with `"The term 'Format-MetaQueryXml' is not recognized"`

- [ ] **Step 3: Commit failing tests**

```bash
git add Tests/cprompt.Tests.ps1
git commit -m "test(meta-query): add failing tests for Format-MetaQueryXml"
```

---

### Task 4: `Format-MetaQueryXml` — implementation

**Files:**
- Modify: `cprompt.psm1` (add function after `Test-InputIsMetaQuery`, update Export-ModuleMember)

- [ ] **Step 1: Implement `Format-MetaQueryXml`**

Add this function after `Test-InputIsMetaQuery` in `cprompt.psm1`:

```powershell
function Format-MetaQueryXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $parts = @()
    if ($Context.Branch) { $parts += "Branch: $($Context.Branch)" }
    if ($Context.Status) {
        $statusLines = @(($Context.Status -split "`n") | Where-Object { $_.Trim() })
        $parts += "Modified: $($statusLines.Count) file(s)"
        $parts += "Files: $($Context.Status.Trim())"
    }
    if ($Context.Log) {
        $logLines = @(($Context.Log -split "`n") | Where-Object { $_.Trim() })
        $parts += "Recent: $($logLines -join ' | ')"
    }
    if ($Context.Todos) {
        $todoLines = @(($Context.Todos -split "`n") | Where-Object { $_.Trim() })
        $parts += "TODOs: $($todoLines.Count) item(s) -- $($Context.Todos.Trim())"
    }
    $pfKeys = @()
    if ($Context.ProjectFiles -and $Context.ProjectFiles.Count -gt 0) {
        foreach ($k in $Context.ProjectFiles.Keys) { $pfKeys += $k }
        $parts += "Project files: $($pfKeys -join ', ')"
    }

    $contextBody = $parts -join ' | '
    if (-not $contextBody) { $contextBody = 'No project context available' }

    $task = 'Responder consulta de status do projeto'
    $constraints = "Responder a pergunta do usuario: $Question | Listar trabalho pendente, estado atual do repositorio, proximos passos"

    return "<task>$task</task><context>$contextBody</context><constraints>$constraints</constraints>"
}
```

- [ ] **Step 2: Add `Format-MetaQueryXml` to `Export-ModuleMember`**

After the `Test-InputIsMetaQuery, `` ` line, add:

```powershell
    Format-MetaQueryXml, `
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Filter @{FullName='*Format-MetaQueryXml*'} -Output Detailed"`
Expected: All 9 tests PASS

- [ ] **Step 4: Commit**

```bash
git add cprompt.psm1
git commit -m "feat(meta-query): implement Format-MetaQueryXml synthetic envelope builder"
```

---

### Task 5: `Get-ProjectContext` — failing tests

**Files:**
- Test: `Tests/cprompt.Tests.ps1` (append after `Format-MetaQueryXml` Describe block)

- [ ] **Step 1: Write failing tests for `Get-ProjectContext`**

Append after the `Format-MetaQueryXml` Describe block:

```powershell
Describe 'Get-ProjectContext' {
    BeforeAll {
        # Save real commands so we can mock them
        $script:testDir = Join-Path $TestDrive 'fake-repo'
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
    }

    It 'returns hashtable with expected keys' {
        Mock git {
            param()
            $allArgs = $args -join ' '
            if ($allArgs -match 'status') { return 'M  file.ps1' }
            if ($allArgs -match 'branch') { return 'main' }
            if ($allArgs -match 'log')    { return 'abc1234 test commit' }
            if ($allArgs -match 'diff --name-only') { return 'file.ps1' }
            return ''
        }
        Mock Select-String { return $null }

        $result = Get-ProjectContext -Path $script:testDir
        $result           | Should -Not -BeNullOrEmpty
        $result.Branch    | Should -Be 'main'
        $result.Status    | Should -Match 'file.ps1'
        $result.Log       | Should -Match 'abc1234'
        $result.Keys      | Should -Contain 'ElapsedMs'
        $result.Keys      | Should -Contain 'Todos'
        $result.Keys      | Should -Contain 'ProjectFiles'
    }

    It 'fires progress callback for each step' {
        Mock git { return '' }
        Mock Select-String { return $null }

        $msgs = @()
        $result = Get-ProjectContext -Path $script:testDir -OnProgress { $msgs += $args[0] }
        $msgs.Count | Should -BeGreaterOrEqual 3
        $msgs[0] | Should -Match '\[1/4\]'
        $msgs[1] | Should -Match '\[2/4\]'
    }

    It 'caps TODO output at 30 lines' {
        $longTodos = (1..50 | ForEach-Object { "file.ps1:$_`: # TODO item $_" }) -join "`n"
        Mock git {
            param()
            $allArgs = $args -join ' '
            if ($allArgs -match 'diff --name-only') { return 'file.ps1' }
            return ''
        }
        Mock Select-String {
            $lines = (1..50 | ForEach-Object {
                [pscustomobject]@{ Line = "file.ps1:$_`: # TODO item $_" }
            })
            return $lines
        }

        $result = Get-ProjectContext -Path $script:testDir
        if ($result.Todos) {
            $todoLines = @(($result.Todos -split "`n") | Where-Object { $_.Trim() })
            $todoLines.Count | Should -BeLessOrEqual 30
        }
    }

    It 'caps project file content at 2000 chars' {
        $longContent = 'x' * 5000
        Mock git { return '' }
        Mock Select-String { return $null }

        $claudeMd = Join-Path $script:testDir 'CLAUDE.md'
        Set-Content -LiteralPath $claudeMd -Value $longContent -Encoding UTF8

        $result = Get-ProjectContext -Path $script:testDir
        if ($result.ProjectFiles -and $result.ProjectFiles['CLAUDE.md']) {
            $result.ProjectFiles['CLAUDE.md'].Length | Should -BeLessOrEqual 2000
        }

        Remove-Item -LiteralPath $claudeMd -Force -ErrorAction SilentlyContinue
    }

    It 'skips TODO step when BudgetMs is exceeded' {
        Mock git {
            param()
            Start-Sleep -Milliseconds 50
            return ''
        }
        Mock Select-String { return $null }

        $result = Get-ProjectContext -Path $script:testDir -BudgetMs 1
        $result.Todos | Should -BeNullOrEmpty
    }

    It 'reads CLAUDE.md and README.md when present' {
        Mock git { return '' }
        Mock Select-String { return $null }

        $claudeMd = Join-Path $script:testDir 'CLAUDE.md'
        $readmeMd = Join-Path $script:testDir 'README.md'
        Set-Content -LiteralPath $claudeMd -Value 'claude content' -Encoding UTF8
        Set-Content -LiteralPath $readmeMd -Value 'readme content' -Encoding UTF8

        $result = Get-ProjectContext -Path $script:testDir
        $result.ProjectFiles['CLAUDE.md'] | Should -Match 'claude content'
        $result.ProjectFiles['README.md'] | Should -Match 'readme content'

        Remove-Item -LiteralPath $claudeMd -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $readmeMd -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Filter @{FullName='*Get-ProjectContext*'} -Output Detailed"`
Expected: All tests FAIL with `"The term 'Get-ProjectContext' is not recognized"`

- [ ] **Step 3: Commit failing tests**

```bash
git add Tests/cprompt.Tests.ps1
git commit -m "test(meta-query): add failing tests for Get-ProjectContext"
```

---

### Task 6: `Get-ProjectContext` — implementation

**Files:**
- Modify: `cprompt.psm1` (add function after `Test-InputIsMetaQuery`, update Export-ModuleMember)

- [ ] **Step 1: Implement `Get-ProjectContext`**

Add this function after `Test-InputIsMetaQuery` and before `Format-MetaQueryXml` in `cprompt.psm1`:

```powershell
function Get-ProjectContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OnProgress,
        [int]$BudgetMs = 0
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $notify = { param($msg) if ($OnProgress) { & $OnProgress $msg } }

    $overBudget = {
        if ($BudgetMs -le 0) { return $false }
        return ($sw.ElapsedMilliseconds -ge $BudgetMs)
    }

    $result = @{
        Branch       = ''
        Status       = ''
        Log          = ''
        Todos        = $null
        ProjectFiles = @{}
        ElapsedMs    = 0
    }

    $savedLocation = Get-Location
    try {
        Set-Location -LiteralPath $Path

        # Step 1: git status
        & $notify '[1/4] git status...'
        try { $result.Status = (git status --short 2>$null | Out-String).Trim() } catch {}

        # Step 2: git log + branch
        & $notify '[2/4] git log...'
        try { $result.Branch = (git branch --show-current 2>$null | Out-String).Trim() } catch {}
        try { $result.Log = (git log --oneline -15 2>$null | Out-String).Trim() } catch {}

        # Step 3: TODOs (budget-gated)
        if (-not (& $overBudget)) {
            & $notify '[3/4] scanning TODOs...'
            try {
                $changedFiles = @(git diff --name-only HEAD~50 2>$null | Where-Object { $_.Trim() })
                if ($changedFiles.Count -gt 0) {
                    $existingFiles = @($changedFiles | Where-Object { Test-Path -LiteralPath $_ })
                    if ($existingFiles.Count -gt 0) {
                        $matches = @(Select-String -Pattern 'TODO|FIXME|HACK' -Path $existingFiles -ErrorAction SilentlyContinue |
                            Select-Object -First 30 |
                            ForEach-Object { "$($_.RelativePath):$($_.LineNumber): $($_.Line.Trim())" })
                        if ($matches.Count -gt 0) {
                            $result.Todos = $matches -join "`n"
                        }
                    }
                }
            } catch {}
        }

        # Step 4: project files
        & $notify '[4/4] project files...'
        foreach ($fname in @('CLAUDE.md', 'README.md')) {
            $fpath = Join-Path $Path $fname
            if (Test-Path -LiteralPath $fpath) {
                $content = Get-Content -LiteralPath $fpath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content -and $content.Length -gt 2000) {
                    $content = $content.Substring(0, 2000)
                }
                if ($content) { $result.ProjectFiles[$fname] = $content }
            }
        }
    } finally {
        Set-Location -LiteralPath $savedLocation
    }

    $sw.Stop()
    $result.ElapsedMs = [int]$sw.ElapsedMilliseconds
    return $result
}
```

- [ ] **Step 2: Add `Get-ProjectContext` to `Export-ModuleMember`**

After the `Test-InputIsMetaQuery, `` ` line, add:

```powershell
    Get-ProjectContext, `
```

The Export-ModuleMember block should now include (in order after `Test-InputIsZeroSignal`):

```powershell
    Test-InputIsMetaQuery, `
    Get-ProjectContext, `
    Format-MetaQueryXml, `
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Filter @{FullName='*Get-ProjectContext*'} -Output Detailed"`
Expected: All 6 tests PASS

- [ ] **Step 4: Run full unit test suite to check for regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1
git commit -m "feat(meta-query): implement Get-ProjectContext with budget-gated TODO scan"
```

---

### Task 7: Pipeline integration in `c.ps1`

**Files:**
- Modify: `c.ps1:1-3` (param block — add `-MetaQuery`)
- Modify: `c.ps1:88-99` (add `$contextGatherMs` variable)
- Modify: `c.ps1:102` (meta-query stage before `$skipRefiner` line)
- Modify: `c.ps1:274-290` (add `contextGatherMs` to metrics entry)

- [ ] **Step 1: Add `-MetaQuery` switch to param block**

In `c.ps1`, add `-MetaQuery` switch to the param block. After `[switch]$Interactive,` (line 9), add:

```powershell
    [switch]$MetaQuery,
```

- [ ] **Step 2: Add `$contextGatherMs` variable initialization**

After `$compilerStats = $null` (line 94), add:

```powershell
$contextGatherMs = 0
```

- [ ] **Step 3: Add meta-query stage before `$skipRefiner` assignment**

Insert the following block **before** line 101 (`# '-Raw' implies '-NoRefine'...`), after the `$contextGatherMs = 0` line:

```powershell
# Meta-query stage: status/progress questions skip refiner + compiler entirely.
# Gather project context from git, TODOs, project files and build synthetic XML.
if ($MetaQuery -or (Test-InputIsMetaQuery -Text $userInput)) {
    if (-not $Raw) {
        Write-Host '--- consulta de status detectada ---' -ForegroundColor DarkCyan
    }
    $budgetMs = if ($NonInteractive) { 3000 } else { 0 }
    $progressCb = if ($Raw) { $null } else { { param($m) Write-Host $m -ForegroundColor DarkGray } }
    $ctxWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $projectCtx = Get-ProjectContext -Path (Get-Location).Path -OnProgress $progressCb -BudgetMs $budgetMs
    $ctxWatch.Stop()
    $contextGatherMs = [int]$ctxWatch.ElapsedMilliseconds
    $xml = Format-MetaQueryXml -Question $rawInput -Context $projectCtx
    $metricMode = 'meta-query'

    # Skip to output — jump past pregate, refiner, compiler, and cache stages.
    # History, metrics, and output handling (line 261+) still run normally.
    $skipRefiner = $true
    $fromCache   = $false
}
```

- [ ] **Step 4: Add `contextGatherMs` to metrics entry**

In the metrics block (around line 283 after the edit), add `contextGatherMs` to the `$entry` hashtable. After the `compilerMs` line, add:

```powershell
        contextGatherMs = $contextGatherMs
```

- [ ] **Step 5: Update `Show-Usage` to document `-MetaQuery` flag**

In the `Show-Usage` function, after the `-NoCache` line (around line 37), add:

```powershell
      c <ideia> -MetaQuery         forca modo meta-query (injeta contexto do projeto)
```

- [ ] **Step 6: Run full unit test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Output Detailed"`
Expected: All tests PASS (no regressions)

- [ ] **Step 7: Commit**

```bash
git add c.ps1
git commit -m "feat(meta-query): add pipeline stage and -MetaQuery flag to c.ps1"
```

---

### Task 8: Hook cleanup — delete meta-question regex from `c-autorefine.ps1`

**Files:**
- Modify: `hooks/c-autorefine.ps1:15` (update comment block)
- Modify: `hooks/c-autorefine.ps1:51-54` (delete meta-question regex + exit)

- [ ] **Step 1: Delete the meta-question regex block**

In `hooks/c-autorefine.ps1`, delete lines 51-54:

```powershell
    # Meta / status questions: WH-word start AND ends with `?`. False positives
    # on dev-task questions are acceptable — those just pass through unrefined.
    $metaQuestion = '(?i)^\s*(qual|que|o que|por que|como|quando|onde|what|why|how|when|where|which|who|whose)\b.*\?\s*$'
    if ($trim -match $metaQuestion) { exit 0 }
```

- [ ] **Step 2: Update the comment block at top of file**

In the comment block at line 15, remove the bullet about meta/status questions:

Change:
```powershell
#   - Meta / status questions (WH-word + ?, no programming keyword)
```

To:
```powershell
#   - Meta / status questions are now handled by c.ps1 internally (Test-InputIsMetaQuery)
```

- [ ] **Step 3: Verify hook still works for normal prompts**

Run: `pwsh -NoProfile -Command "echo '{\"prompt\":\"implementa cache lru em go\"}' | pwsh -NoProfile -File hooks/c-autorefine.ps1"`
Expected: exits 0 (would normally call c.ps1 — may error without ollama, but structure is correct)

- [ ] **Step 4: Commit**

```bash
git add hooks/c-autorefine.ps1
git commit -m "refactor(hook): delete meta-question regex, delegate to c.ps1 Test-InputIsMetaQuery"
```

---

### Task 9: Integration tests for meta-query path

**Files:**
- Modify: `Tests/c.Integration.Tests.ps1` (append new Describe block)

The meta-query path does NOT call ollama (skips refiner + compiler). It calls `git` commands instead. The integration test framework stubs `ollama` via PATH manipulation. For meta-query tests, we need the git commands to succeed. Since `Invoke-CIntegration` sets a minimal PATH (`$binDir;System32;...`), git may not be on it. We need to add a `git.cmd` stub or include git in the PATH.

Simplest approach: add git to the PATH for these tests. `Invoke-CIntegration` does not currently support custom PATH entries, but we can create a git stub similar to the ollama stub.

- [ ] **Step 1: Create git stub for integration tests**

Create `Tests/integration/git.cmd`:
```batch
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0git-impl.ps1" %*
exit /b %ERRORLEVEL%
```

Create `Tests/integration/git-impl.ps1`:
```powershell
# Test stub for git. Returns canned output based on subcommand.
$sub = if ($args.Count -gt 0) { $args[0] } else { '' }

switch ($sub) {
    'status' {
        [Console]::Out.Write("M  src/app.ps1`n?? newfile.txt")
        exit 0
    }
    'branch' {
        [Console]::Out.Write('feat/meta-query')
        exit 0
    }
    'log' {
        [Console]::Out.Write("abc1234 feat: add meta-query`ndef5678 fix: auth bug`nghi9012 docs: update readme")
        exit 0
    }
    'diff' {
        [Console]::Out.Write("src/app.ps1`nsrc/lib.ps1")
        exit 0
    }
    default {
        exit 0
    }
}
```

- [ ] **Step 2: Add meta-query integration test Describe block**

Append to `Tests/c.Integration.Tests.ps1`:

```powershell
Describe 'c.ps1 meta-query path' {
    It 'meta-query input skips refiner and compiler, produces synthetic XML' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Raw','o que temos para fazer agora?') `
            -Stubs @('ollama','git')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Not -Contain 'prompt-opt'
        $r.Invocations | Should -Not -Contain 'prompt-refiner'
        $r.StdOut      | Should -Match '<task>Responder consulta de status do projeto</task>'
        $r.StdOut      | Should -Match 'feat/meta-query'
    }

    It '-MetaQuery flag forces meta-query path on non-meta input' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-MetaQuery','-Raw','sistema ecs unity') `
            -Stubs @('ollama','git')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Not -Contain 'prompt-opt'
        $r.StdOut      | Should -Match '<task>Responder consulta de status do projeto</task>'
    }

    It 'metrics record mode=meta-query and contextGatherMs' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Raw','what is the current status?') `
            -Stubs @('ollama','git')

        $r.ExitCode | Should -Be 0
        $metricsLine = Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $metrics = $metricsLine | ConvertFrom-Json
        $metrics.mode | Should -Be 'meta-query'
        $metrics.contextGatherMs | Should -BeGreaterOrEqual 0
        $metrics.compilerMs | Should -Be 0
        $metrics.refinerMs  | Should -Be 0
    }
}
```

- [ ] **Step 3: Run integration tests**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/c.Integration.Tests.ps1 -Filter @{FullName='*meta-query*'} -Output Detailed"`
Expected: All 3 tests PASS

- [ ] **Step 4: Run full integration test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/c.Integration.Tests.ps1 -Output Detailed"`
Expected: All tests PASS (no regressions)

- [ ] **Step 5: Commit**

```bash
git add Tests/integration/git.cmd Tests/integration/git-impl.ps1 Tests/c.Integration.Tests.ps1
git commit -m "test(meta-query): add integration tests with git stub"
```

---

### Task 10: Full regression check + final commit

**Files:** None (verification only)

- [ ] **Step 1: Run all unit tests**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/cprompt.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

- [ ] **Step 2: Run all integration tests**

Run: `pwsh -NoProfile -Command "Invoke-Pester Tests/c.Integration.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

- [ ] **Step 3: Manual smoke test — CLI meta-query**

Run from a git repo: `pwsh -NoProfile -File c.ps1 "o que temos para fazer agora?"`
Expected: See progress messages `[1/4]...[4/4]`, then synthetic XML on screen, XML copied to clipboard.

- [ ] **Step 4: Manual smoke test — CLI normal prompt**

Run: `pwsh -NoProfile -File c.ps1 -NoRefine "implementa cache lru em go"`
Expected: Normal compiler flow, no meta-query stage triggered.

- [ ] **Step 5: Manual smoke test — `-MetaQuery` flag**

Run: `pwsh -NoProfile -File c.ps1 -MetaQuery "implementa cache lru em go"`
Expected: Meta-query path forced, synthetic XML output.
