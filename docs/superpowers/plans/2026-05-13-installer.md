# Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `install.ps1` and `uninstall.ps1` so users can run a single command to set up TRANSLaiTOR on a fresh machine (with the official Ollama MSI already installed) and a single command to remove every trace of it later.

**Architecture:** Pure helpers (`Test-PathContainsEntry`, `Add-PathEntry`, `Remove-PathEntry`) live in a new module `cinstall.psm1` and are unit-tested with Pester v3 the same way `cprompt.psm1` is. The CLI scripts `install.ps1` and `uninstall.ps1` are thin orchestrators that compose the helpers, shell out to `ollama`, and edit `HKCU:\Environment` via `[Environment]::SetEnvironmentVariable(name, value, 'User')` — that overload writes the registry **and** broadcasts `WM_SETTINGCHANGE` automatically, so new shells pick up the change. No admin elevation needed; everything happens at user scope. The installer is idempotent (re-running is safe and skips already-completed steps); the uninstaller defaults to safe removal (built local models + PATH/PATHEXT entries) and gates destructive cleanups (`-PurgeBase`, `-PurgeState`) behind explicit switches.

**Tech Stack:** PowerShell 5.1+, Pester v3 (`Should Be` not `Should -Be`), `ollama` CLI, `[Environment]::SetEnvironmentVariable` for HKCU env vars.

**Branch:** `feat/installer` off `main` (currently `dd6db50`).

---

## File Structure

- Create: `C:\Users\hhthu\Scripts\cinstall.psm1` — pure helpers for PATH-string manipulation and ollama-model-list parsing. One responsibility: install-related logic that benefits from unit tests.
- Create: `C:\Users\hhthu\Scripts\install.ps1` — CLI orchestrator. Composes helpers, shells out to `ollama`, writes HKCU env vars.
- Create: `C:\Users\hhthu\Scripts\uninstall.ps1` — CLI orchestrator. Reverses what `install.ps1` did, gated by switches.
- Create: `C:\Users\hhthu\Scripts\Tests\cinstall.Tests.ps1` — Pester v3 tests for `cinstall.psm1`.
- Modify: `C:\Users\hhthu\Scripts\README.md` — add a short "Install via script" subsection at the top of `## Install` that points at `install.ps1`, keeps the existing manual six-step walkthrough as the fallback path, and adds an `## Uninstall` section.

`cprompt.psm1` is NOT touched. Install logic is install-specific; mixing it into `cprompt.psm1` would dilute that file's responsibility (prompt-distillation helpers).

**Helper contract (in `cinstall.psm1`):**

```powershell
Test-PathContainsEntry -PathString $env:Path -Entry 'C:\Tools'   # → [bool], case-insensitive
Add-PathEntry          -PathString $env:Path -Entry 'C:\Tools'   # → new string (idempotent; trailing ; tolerated)
Remove-PathEntry       -PathString $env:Path -Entry 'C:\Tools'   # → new string (removes all matching segments)
```

All three are pure string functions. The CLIs read the current HKCU env via `[Environment]::GetEnvironmentVariable($name, 'User')`, pass it through the helper, and write it back via `[Environment]::SetEnvironmentVariable($name, $new, 'User')`.

---

### Task 1: Create feature branch

**Files:** none yet.

- [ ] **Step 1: Verify clean main**

Run: `git -C C:/Users/hhthu/Scripts status`
Expected: `On branch main` and `nothing to commit, working tree clean`.

- [ ] **Step 2: Create branch**

Run: `git -C C:/Users/hhthu/Scripts checkout -b feat/installer`
Expected: `Switched to a new branch 'feat/installer'`.

- [ ] **Step 3: Commit the plan**

```bash
git -C C:/Users/hhthu/Scripts add docs/superpowers/plans/2026-05-13-installer.md
git -C C:/Users/hhthu/Scripts commit -m "docs: implementation plan for installer"
```

Expected: one new commit on `feat/installer`.

---

### Task 2: Test-PathContainsEntry (TDD)

**Files:**
- Create: `C:\Users\hhthu\Scripts\cinstall.psm1`
- Create: `C:\Users\hhthu\Scripts\Tests\cinstall.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `Tests\cinstall.Tests.ps1` with this content:

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path (Split-Path -Parent $here) 'cinstall.psm1'
Remove-Module cinstall -ErrorAction SilentlyContinue
Import-Module $module -Force

Describe 'Test-PathContainsEntry' {
    It 'returns $true when the entry appears verbatim' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B;C:\C' -Entry 'C:\B' | Should Be $true
    }

    It 'returns $false when the entry is absent' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should Be $false
    }

    It 'matches case-insensitively' {
        Test-PathContainsEntry -PathString 'C:\Users\HHTHU\Scripts' -Entry 'c:\users\hhthu\scripts' | Should Be $true
    }

    It 'tolerates a trailing semicolon in the PathString' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B;' -Entry 'C:\B' | Should Be $true
    }

    It 'matches a whole segment, not a substring' {
        # "C:\B" must NOT match inside "C:\Bin".
        Test-PathContainsEntry -PathString 'C:\A;C:\Bin' -Entry 'C:\B' | Should Be $false
    }

    It 'returns $false on an empty PathString' {
        Test-PathContainsEntry -PathString '' -Entry 'C:\A' | Should Be $false
    }

    It 'treats a null PathString as empty' {
        Test-PathContainsEntry -PathString $null -Entry 'C:\A' | Should Be $false
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit"`
Expected: failures — the module file does not exist yet, so Import-Module fails. That is the expected starting state.

- [ ] **Step 3: Create `cinstall.psm1` with the function**

```powershell
Set-StrictMode -Version Latest

function Test-PathContainsEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathString,
        [Parameter(Mandatory)][string]$Entry
    )
    if ([string]::IsNullOrEmpty($PathString)) { return $false }
    $segments = $PathString -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    foreach ($s in $segments) {
        if ($s.Equals($Entry, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

Export-ModuleMember -Function Test-PathContainsEntry
```

- [ ] **Step 4: Re-run the tests**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit"`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/hhthu/Scripts add cinstall.psm1 Tests/cinstall.Tests.ps1
git -C C:/Users/hhthu/Scripts commit -m "feat(installer): Test-PathContainsEntry (whole-segment, case-insensitive)"
```

---

### Task 3: Add-PathEntry (TDD)

**Files:**
- Modify: `C:\Users\hhthu\Scripts\cinstall.psm1`
- Modify: `C:\Users\hhthu\Scripts\Tests\cinstall.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `Tests\cinstall.Tests.ps1`:

```powershell
Describe 'Add-PathEntry' {
    It 'appends to a non-empty PathString with a separating semicolon' {
        Add-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should Be 'C:\A;C:\B;C:\C'
    }

    It 'returns just the entry when PathString is empty' {
        Add-PathEntry -PathString '' -Entry 'C:\A' | Should Be 'C:\A'
    }

    It 'returns just the entry when PathString is null' {
        Add-PathEntry -PathString $null -Entry 'C:\A' | Should Be 'C:\A'
    }

    It 'returns the PathString unchanged when the entry is already present' {
        Add-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\B' | Should Be 'C:\A;C:\B'
    }

    It 'is case-insensitive when checking for existing presence' {
        Add-PathEntry -PathString 'C:\users\HHTHU\Scripts' -Entry 'C:\Users\hhthu\scripts' | Should Be 'C:\users\HHTHU\Scripts'
    }

    It 'strips a single trailing semicolon before appending' {
        Add-PathEntry -PathString 'C:\A;C:\B;' -Entry 'C:\C' | Should Be 'C:\A;C:\B;C:\C'
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit"`
Expected: 6 new failures with "The term 'Add-PathEntry' is not recognized".

- [ ] **Step 3: Add the function in `cinstall.psm1`**

Insert after `Test-PathContainsEntry` (before the `Export-ModuleMember` line):

```powershell
function Add-PathEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathString,
        [Parameter(Mandatory)][string]$Entry
    )
    if ([string]::IsNullOrEmpty($PathString)) { return $Entry }
    if (Test-PathContainsEntry -PathString $PathString -Entry $Entry) {
        return $PathString
    }
    $trimmed = $PathString.TrimEnd(';')
    return "$trimmed;$Entry"
}
```

Update the export line to include both functions:

```powershell
Export-ModuleMember -Function Test-PathContainsEntry, Add-PathEntry
```

- [ ] **Step 4: Re-run the tests**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit"`
Expected: all 13 tests pass (7 + 6).

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/hhthu/Scripts add cinstall.psm1 Tests/cinstall.Tests.ps1
git -C C:/Users/hhthu/Scripts commit -m "feat(installer): Add-PathEntry (idempotent, trims trailing semicolon)"
```

---

### Task 4: Remove-PathEntry (TDD)

**Files:**
- Modify: `C:\Users\hhthu\Scripts\cinstall.psm1`
- Modify: `C:\Users\hhthu\Scripts\Tests\cinstall.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `Tests\cinstall.Tests.ps1`:

```powershell
Describe 'Remove-PathEntry' {
    It 'removes a middle entry and rejoins with semicolons' {
        Remove-PathEntry -PathString 'C:\A;C:\B;C:\C' -Entry 'C:\B' | Should Be 'C:\A;C:\C'
    }

    It 'removes a leading entry' {
        Remove-PathEntry -PathString 'C:\B;C:\A' -Entry 'C:\B' | Should Be 'C:\A'
    }

    It 'removes a trailing entry' {
        Remove-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\B' | Should Be 'C:\A'
    }

    It 'returns the PathString unchanged when the entry is absent' {
        Remove-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should Be 'C:\A;C:\B'
    }

    It 'matches case-insensitively when removing' {
        Remove-PathEntry -PathString 'C:\A;C:\Users\hhthu\Scripts;C:\C' -Entry 'c:\users\hhthu\scripts' |
            Should Be 'C:\A;C:\C'
    }

    It 'removes all duplicate occurrences' {
        Remove-PathEntry -PathString 'C:\A;C:\B;C:\B;C:\C' -Entry 'C:\B' | Should Be 'C:\A;C:\C'
    }

    It 'returns an empty string when only the entry was present' {
        Remove-PathEntry -PathString 'C:\B' -Entry 'C:\B' | Should Be ''
    }

    It 'returns an empty string when PathString is null' {
        Remove-PathEntry -PathString $null -Entry 'C:\B' | Should Be ''
    }

    It 'preserves a non-matching segment that contains the entry as a substring' {
        # "C:\B" must NOT remove "C:\Bin".
        Remove-PathEntry -PathString 'C:\Bin;C:\B' -Entry 'C:\B' | Should Be 'C:\Bin'
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit"`
Expected: 9 new failures with "The term 'Remove-PathEntry' is not recognized".

- [ ] **Step 3: Add the function in `cinstall.psm1`**

Insert after `Add-PathEntry` (before the `Export-ModuleMember` line):

```powershell
function Remove-PathEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathString,
        [Parameter(Mandatory)][string]$Entry
    )
    if ([string]::IsNullOrEmpty($PathString)) { return '' }
    $kept = @()
    foreach ($s in ($PathString -split ';')) {
        $trim = $s.Trim()
        if (-not $trim) { continue }
        if (-not $trim.Equals($Entry, [System.StringComparison]::OrdinalIgnoreCase)) {
            $kept += $trim
        }
    }
    return ($kept -join ';')
}
```

Update the export line to include all three functions:

```powershell
Export-ModuleMember -Function Test-PathContainsEntry, Add-PathEntry, Remove-PathEntry
```

- [ ] **Step 4: Re-run the tests**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit"`
Expected: all 22 tests pass (7 + 6 + 9).

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/hhthu/Scripts add cinstall.psm1 Tests/cinstall.Tests.ps1
git -C C:/Users/hhthu/Scripts commit -m "feat(installer): Remove-PathEntry (whole-segment, removes duplicates)"
```

---

### Task 5: install.ps1

**Files:**
- Create: `C:\Users\hhthu\Scripts\install.ps1`

This is the orchestrator — no new unit-tested logic. The helpers from Tasks 2–4 are already covered. The script does its work via PowerShell, ollama subprocess calls, and HKCU registry writes.

- [ ] **Step 1: Write the script**

Create `C:\Users\hhthu\Scripts\install.ps1` with this content:

```powershell
<#
.SYNOPSIS
    Installs TRANSLaiTOR locally: builds the two Ollama models, adds the
    script directory to the user-level PATH, and registers .PS1 in
    PATHEXT (opt-out via -NoPathExt).

.DESCRIPTION
    Idempotent — re-running skips already-completed steps. Requires
    Ollama already installed (MSI from ollama.com). No admin elevation
    needed; all changes happen at the user scope.
#>
[CmdletBinding()]
param(
    [string]$BaseModel    = 'llama3.2:3b',
    [string]$CompilerName = 'prompt-opt',
    [string]$RefinerName  = 'prompt-refiner',
    [switch]$NoPathExt,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'cinstall.psm1') -Force

function Resolve-OllamaOrFail {
    $cmd = Get-Command 'ollama' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host 'ERRO: ollama nao encontrado no PATH.' -ForegroundColor Red
        Write-Host 'Instale o Ollama MSI primeiro: https://ollama.com' -ForegroundColor Yellow
        exit 2
    }
    return $cmd.Source
}

function Test-OllamaModelPresent {
    param([Parameter(Mandatory)][string]$Name)
    $list = & ollama list 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { return $false }
    # `ollama list` prints a column-aligned table; match the name at start of line.
    return [bool]([regex]::IsMatch($list, "(?im)^$([regex]::Escape($Name))(\:[^\s]+)?\s"))
}

function Invoke-OllamaCreate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Modelfile
    )
    if (-not (Test-Path -LiteralPath $Modelfile)) {
        Write-Host "ERRO: Modelfile nao encontrado: $Modelfile" -ForegroundColor Red
        exit 3
    }
    Write-Host "--- criando modelo $Name ---" -ForegroundColor Cyan
    & ollama create $Name -f $Modelfile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: ollama create $Name falhou (codigo $LASTEXITCODE)." -ForegroundColor Red
        exit 4
    }
}

function Update-UserEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewValue
    )
    [Environment]::SetEnvironmentVariable($Name, $NewValue, 'User')
}

# --- Step 1: ollama present? ---
$null = Resolve-OllamaOrFail
Write-Host "ollama OK: $(& ollama --version 2>$null)" -ForegroundColor DarkGreen

# --- Step 2: base model present? ---
if (Test-OllamaModelPresent -Name $BaseModel) {
    Write-Host "base model $BaseModel ja presente, pulando pull." -ForegroundColor DarkGreen
} else {
    Write-Host "--- baixando $BaseModel (pode demorar uns minutos) ---" -ForegroundColor Cyan
    & ollama pull $BaseModel
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: ollama pull $BaseModel falhou (codigo $LASTEXITCODE)." -ForegroundColor Red
        exit 5
    }
}

# --- Step 3: local models ---
if (Test-OllamaModelPresent -Name $CompilerName) {
    Write-Host "modelo $CompilerName ja existe, recriando para refletir Modelfile.compiler." -ForegroundColor DarkGreen
}
Invoke-OllamaCreate -Name $CompilerName -Modelfile (Join-Path $here 'Modelfile.compiler')

if (Test-OllamaModelPresent -Name $RefinerName) {
    Write-Host "modelo $RefinerName ja existe, recriando para refletir Modelfile.refiner." -ForegroundColor DarkGreen
}
Invoke-OllamaCreate -Name $RefinerName -Modelfile (Join-Path $here 'Modelfile.refiner')

# --- Step 4: PATH ---
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newPath  = Add-PathEntry -PathString $userPath -Entry $here
if ($newPath -ne $userPath) {
    Update-UserEnv -Name 'Path' -NewValue $newPath
    Write-Host "PATH (user) atualizado: $here adicionado." -ForegroundColor DarkGreen
} else {
    Write-Host "PATH (user) ja contem $here, nada a fazer." -ForegroundColor DarkGreen
}

# --- Step 5: PATHEXT (opcional) ---
if (-not $NoPathExt) {
    $userExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'User')
    $newExt  = Add-PathEntry -PathString $userExt -Entry '.PS1'
    if ($newExt -ne $userExt) {
        Update-UserEnv -Name 'PATHEXT' -NewValue $newExt
        Write-Host "PATHEXT (user) atualizado: .PS1 adicionado." -ForegroundColor DarkGreen
    } else {
        Write-Host "PATHEXT (user) ja contem .PS1, nada a fazer." -ForegroundColor DarkGreen
    }
} else {
    Write-Host '(pulando PATHEXT por -NoPathExt; use o c.cmd shim para invocar c sem .ps1)' -ForegroundColor DarkGray
}

# --- Step 6: smoke (opcional) ---
if (-not $SkipSmoke) {
    Write-Host "--- smoke test: c -NoRefine -Raw 'test input' ---" -ForegroundColor Cyan
    & (Join-Path $here 'c.ps1') -NoRefine -Raw 'test input' | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'smoke OK.' -ForegroundColor Green
    } else {
        Write-Host "smoke retornou codigo $LASTEXITCODE (modelo pode estar lento na 1a inferencia; revise manualmente)." -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'instalacao concluida. abra um shell NOVO para PATH/PATHEXT entrarem em efeito.' -ForegroundColor Green
```

- [ ] **Step 2: Static syntax check**

Run: `powershell -NoProfile -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw C:/Users/hhthu/Scripts/install.ps1), [ref]@()); 'OK'"`
Expected: prints `OK` with no parser exception.

- [ ] **Step 3: Help/Get-Help check**

Run: `powershell -NoProfile -Command "Get-Help C:/Users/hhthu/Scripts/install.ps1"`
Expected: prints the comment-based SYNOPSIS / DESCRIPTION without error.

- [ ] **Step 4: Idempotency smoke (only if ollama present)**

Optional. If the developer machine already has `ollama` + the two models built (i.e. they used the manual README install), run:

```powershell
powershell -NoProfile -File C:/Users/hhthu/Scripts/install.ps1 -SkipSmoke -NoPathExt
```

Expected: every step reports "ja presente / ja contem ... nada a fazer", exit 0. (If models are missing, the script will rebuild them — that is correct behaviour, not a bug. Skip this step if ollama is not installed on the build machine.)

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/hhthu/Scripts add install.ps1
git -C C:/Users/hhthu/Scripts commit -m "feat(installer): install.ps1 builds models and registers PATH/PATHEXT"
```

---

### Task 6: uninstall.ps1

**Files:**
- Create: `C:\Users\hhthu\Scripts\uninstall.ps1`

- [ ] **Step 1: Write the script**

Create `C:\Users\hhthu\Scripts\uninstall.ps1` with this content:

```powershell
<#
.SYNOPSIS
    Removes TRANSLaiTOR's local Ollama models and reverts the user-level
    PATH/PATHEXT changes made by install.ps1. Optional switches purge
    the llama3.2:3b base model and the local state directory.

.DESCRIPTION
    Default behaviour: remove prompt-opt / prompt-refiner, drop the
    scripts directory from user PATH, drop .PS1 from user PATHEXT.
    -PurgeBase    additionally removes llama3.2:3b.
    -PurgeState   additionally deletes %USERPROFILE%\.cprompt (cache,
                  history, metrics).
    -Force        skips the per-step confirmation prompt.
#>
[CmdletBinding()]
param(
    [string]$BaseModel    = 'llama3.2:3b',
    [string]$CompilerName = 'prompt-opt',
    [string]$RefinerName  = 'prompt-refiner',
    [switch]$PurgeBase,
    [switch]$PurgeState,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'cinstall.psm1') -Force

function Confirm-Or-Exit {
    param([Parameter(Mandatory)][string]$Message)
    if ($Force) { return }
    $reply = Read-Host "$Message [y/N]"
    if ($reply -notmatch '^[yY]') {
        Write-Host 'abortado.' -ForegroundColor Yellow
        exit 0
    }
}

function Remove-OllamaModel {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command 'ollama' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "ollama nao encontrado, pulando rm $Name." -ForegroundColor DarkGray
        return
    }
    Write-Host "--- removendo modelo $Name ---" -ForegroundColor Cyan
    & ollama rm $Name 2>$null
    # `ollama rm` returns nonzero if the model was already absent — silent in that case.
}

function Update-UserEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewValue
    )
    [Environment]::SetEnvironmentVariable($Name, $NewValue, 'User')
}

# --- Confirm ---
$summary = @(
    "remover modelo $CompilerName",
    "remover modelo $RefinerName",
    "remover $here do PATH (user)",
    'remover .PS1 do PATHEXT (user)'
)
if ($PurgeBase)  { $summary += "remover base model $BaseModel" }
if ($PurgeState) { $summary += "apagar $env:USERPROFILE\.cprompt (cache+history+metrics)" }
Write-Host 'desinstalacao planejada:' -ForegroundColor Cyan
foreach ($line in $summary) { Write-Host "  - $line" }
Confirm-Or-Exit 'prosseguir?'

# --- Local models ---
Remove-OllamaModel -Name $CompilerName
Remove-OllamaModel -Name $RefinerName

# --- PATH ---
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newPath  = Remove-PathEntry -PathString $userPath -Entry $here
if ($newPath -ne $userPath) {
    Update-UserEnv -Name 'Path' -NewValue $newPath
    Write-Host "PATH (user) limpo: $here removido." -ForegroundColor DarkGreen
} else {
    Write-Host "PATH (user) nao continha $here." -ForegroundColor DarkGray
}

# --- PATHEXT ---
$userExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'User')
$newExt  = Remove-PathEntry -PathString $userExt -Entry '.PS1'
if ($newExt -ne $userExt) {
    Update-UserEnv -Name 'PATHEXT' -NewValue $newExt
    Write-Host 'PATHEXT (user) limpo: .PS1 removido.' -ForegroundColor DarkGreen
} else {
    Write-Host 'PATHEXT (user) nao continha .PS1.' -ForegroundColor DarkGray
}

# --- Base model (opt-in) ---
if ($PurgeBase) {
    Remove-OllamaModel -Name $BaseModel
}

# --- State directory (opt-in) ---
if ($PurgeState) {
    $stateDir = Join-Path $env:USERPROFILE '.cprompt'
    if (Test-Path -LiteralPath $stateDir) {
        Remove-Item -LiteralPath $stateDir -Recurse -Force
        Write-Host "$stateDir apagado." -ForegroundColor DarkGreen
    } else {
        Write-Host "$stateDir nao existia." -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'desinstalacao concluida. abra um shell NOVO para PATH/PATHEXT entrarem em efeito.' -ForegroundColor Green
```

- [ ] **Step 2: Static syntax check**

Run: `powershell -NoProfile -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw C:/Users/hhthu/Scripts/uninstall.ps1), [ref]@()); 'OK'"`
Expected: prints `OK`.

- [ ] **Step 3: Help check**

Run: `powershell -NoProfile -Command "Get-Help C:/Users/hhthu/Scripts/uninstall.ps1"`
Expected: prints SYNOPSIS / DESCRIPTION without error.

- [ ] **Step 4: Dry-confirm (no destructive ops)**

Run uninstall.ps1 interactively, but answer `N` at the prompt:

```powershell
powershell -NoProfile -File C:/Users/hhthu/Scripts/uninstall.ps1
# When prompted, type N and press Enter.
```

Expected: prints the planned-uninstall summary, exits 0 with `abortado.`. No env vars, models, or state should change.

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/hhthu/Scripts add uninstall.ps1
git -C C:/Users/hhthu/Scripts commit -m "feat(installer): uninstall.ps1 reverses install with opt-in purges"
```

---

### Task 7: README updates

**Files:**
- Modify: `C:\Users\hhthu\Scripts\README.md`

- [ ] **Step 1: Add a scripted-install subsection inside `## Install`**

Find the existing `## Install` heading and insert this subsection BETWEEN the heading and the existing "The instructions below assume..." paragraph:

```markdown
### Scripted install (recommended)

After installing the Ollama MSI from <https://ollama.com>, clone the repo
and run:

\`\`\`powershell
git clone https://github.com/hhthunderbird/TRANSLaiTOR.git $env:USERPROFILE\Scripts
& $env:USERPROFILE\Scripts\install.ps1
\`\`\`

The installer is idempotent: re-running it is safe and skips
already-completed steps. Switches:

- `-NoPathExt` — skip registering `.PS1` in `PATHEXT` (use the bundled
  `c.cmd` shim instead).
- `-SkipSmoke` — skip the post-install `c -NoRefine -Raw 'test input'`
  invocation.

### Manual install
```

(Note: keep the trailing `### Manual install` heading. The existing
"The instructions below assume..." paragraph and the six numbered steps
now live under that heading.)

(In the actual edit, replace the escaped fences `\`\`\`` with literal triple backticks. They are escaped here to keep this plan file's outer fence valid.)

- [ ] **Step 2: Add an `## Uninstall` section**

Insert this section IMMEDIATELY AFTER the existing `## Install` block (i.e. after the `## Install` content ends and BEFORE the `## Usage` heading):

```markdown
## Uninstall

\`\`\`powershell
& $env:USERPROFILE\Scripts\uninstall.ps1
\`\`\`

By default the uninstaller removes the two local models and reverts the
PATH/PATHEXT entries the installer added. Optional purges:

- `-PurgeBase`  — also removes the `llama3.2:3b` base model.
- `-PurgeState` — also deletes `%USERPROFILE%\.cprompt\` (cache, history,
  metrics). Irreversible.
- `-Force`      — skip the confirmation prompt.

The script never deletes the repo directory itself — remove that
manually when you are done.
```

(Same fence-escape note as Step 1.)

- [ ] **Step 3: Update the Files list**

Find the `## Files` section and append two new bullets to the list:

```markdown
- `install.ps1` — scripted installer (idempotent; user-scope env vars).
- `uninstall.ps1` — reverses `install.ps1`; optional `-PurgeBase` / `-PurgeState`.
- `cinstall.psm1` — pure helpers for PATH-string manipulation.
- `Tests/cinstall.Tests.ps1` — Pester v3 unit tests for cinstall.
```

(Place these bullets right after the existing `cstats.ps1` bullet so installer/uninstaller artefacts cluster together.)

- [ ] **Step 4: Commit**

```bash
git -C C:/Users/hhthu/Scripts add README.md
git -C C:/Users/hhthu/Scripts commit -m "docs: README documents install.ps1 and uninstall.ps1"
```

---

### Task 8: Push and open PR

- [ ] **Step 1: Re-run all tests one last time**

Run: `powershell -NoProfile -Command "Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cinstall.Tests.ps1' -EnableExit; Invoke-Pester -Script 'C:/Users/hhthu/Scripts/Tests/cprompt.Tests.ps1' -EnableExit"`
Expected: cinstall 22/0; cprompt 75/0.

- [ ] **Step 2: Push**

Run: `git -C C:/Users/hhthu/Scripts push -u origin feat/installer`
Expected: branch published.

- [ ] **Step 3: Open the PR**

```bash
cd C:/Users/hhthu/Scripts && gh pr create --title "feat(installer): install.ps1 and uninstall.ps1 with HKCU env edits" --body "$(cat <<'EOF'
## Summary

- Adds `install.ps1` — idempotent installer that verifies `ollama` is on `PATH`, pulls `llama3.2:3b` (skipping if already present), (re)builds `prompt-opt` and `prompt-refiner` from the bundled Modelfiles, adds the script directory to user-level `PATH`, and registers `.PS1` in user-level `PATHEXT` (opt-out via `-NoPathExt`). Optional smoke test (`-SkipSmoke` to disable).
- Adds `uninstall.ps1` — confirms a plan, then removes `prompt-opt` / `prompt-refiner`, drops the script directory from user `PATH`, drops `.PS1` from user `PATHEXT`. Optional `-PurgeBase` also removes `llama3.2:3b`; optional `-PurgeState` also deletes `%USERPROFILE%\.cprompt\`. `-Force` skips the prompt.
- Adds `cinstall.psm1` with three pure helpers — `Test-PathContainsEntry`, `Add-PathEntry`, `Remove-PathEntry` — all whole-segment, case-insensitive, trailing-semicolon-tolerant. Covered by 22 Pester v3 tests in `Tests/cinstall.Tests.ps1`.
- Env var writes go through `[Environment]::SetEnvironmentVariable($name, $value, 'User')`, which writes the HKCU registry and broadcasts `WM_SETTINGCHANGE` automatically — no admin elevation required, new shells pick up the change.
- README adds a "Scripted install (recommended)" subsection (the existing six-step manual walkthrough stays as the "Manual install" fallback) and a new `## Uninstall` section.

## Test plan

- [x] `Invoke-Pester Tests/cinstall.Tests.ps1 -EnableExit` → 22/0 passing.
- [x] `Invoke-Pester Tests/cprompt.Tests.ps1 -EnableExit` → 75/0 passing (unchanged baseline).
- [ ] On a clean machine with Ollama MSI installed: `./install.ps1` exits 0 and a fresh shell finds `c -Help` on `PATH`.
- [ ] Running `./install.ps1` a second time on the same machine reports "ja presente / ja contem ... nada a fazer" and exits 0 (idempotency).
- [ ] `./uninstall.ps1` (default, answer y) leaves `ollama list` without `prompt-opt` / `prompt-refiner`, `[Environment]::GetEnvironmentVariable('Path','User')` without the script directory, and `PATHEXT` without `.PS1`.
- [ ] `./uninstall.ps1 -PurgeState -Force` deletes `%USERPROFILE%\.cprompt\` without prompting.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: prints a PR URL.

- [ ] **Step 4: Report the PR URL back to the user**

---

## Self-Review Notes

- **Spec coverage:** Every install/uninstall behaviour discussed in this session maps to a task — Ollama presence check (Task 5), base-model pull (Task 5), local-model build (Task 5), HKCU PATH/PATHEXT edits (Task 5, helpers in Tasks 2–4), idempotency (Tasks 2–5), uninstall mirror (Task 6), opt-in destructive purges (Task 6), README docs (Task 7), PR (Task 8).
- **Placeholder scan:** No TBD / "implement later" / "similar to". All code blocks are complete. The plan deliberately notes that the README task uses `\`\`\`` escapes inside its illustrative code blocks; the actual README must contain real triple backticks.
- **Type consistency:** Function names `Test-PathContainsEntry`, `Add-PathEntry`, `Remove-PathEntry` used consistently across all tasks, the module export list, and the CLI callers. Parameter names `-PathString` / `-Entry` consistent across all three helpers and both CLI callers. `[Environment]::GetEnvironmentVariable` / `SetEnvironmentVariable` with `'User'` scope used identically in both scripts. Switches `-NoPathExt`, `-SkipSmoke`, `-PurgeBase`, `-PurgeState`, `-Force` are introduced in Tasks 5/6 and referenced consistently in the README (Task 7) and the PR body (Task 8).
- **Pester dialect:** v3 (`Should Be`, no dashes) — matches the existing `cprompt.Tests.ps1` style. The new `cinstall.Tests.ps1` is standalone (its own `Import-Module` header), independent of `cprompt.Tests.ps1`, so failures don't cross-contaminate.
- **Strict mode safety:** `install.ps1` and `uninstall.ps1` both set `Set-StrictMode -Version Latest`. All variables are initialised before use. `[Environment]::GetEnvironmentVariable` may return `$null` when the user-level var is unset; the helpers' `[AllowNull()]` parameter attribute accepts that without tripping strict mode.
- **No accidental admin requirement:** All env writes are `'User'` scope (HKCU), file writes are under `%USERPROFILE%`, and `ollama` runs in user context. No `SetEnvironmentVariable(..., 'Machine')` call exists anywhere in this plan.
