# c.ps1 Integration Tests with Mocked Ollama — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 10 Pester 5 integration tests that exercise `c.ps1` end-to-end with a PATH-shim mocking `ollama` (and `claude` for `-Send` tests), covering refiner→compiler happy path, cache hit/miss, Q&A loop, `-NoRefine`, frictionless fallback, and `-Send` with/without `claude`.

**Architecture:** A `.cmd` shim resolved through `$env:Path` dispatches to a PowerShell stub. The stub drains stdin, parses the model name from `$args`, increments a per-test invocation counter, and writes a fixture's payload to stdout. State (cache, history, metrics) lives under `$TestDrive` via a new `$env:CPROMPT_STATE_ROOT` hook in `c.ps1` (1-line production change). The Pester suite spawns `c.ps1` via `Start-Process` with redirected streams and asserts on exit code, stdout, the invocations file, and on-disk state.

**Tech Stack:** PowerShell 5.1, Pester 5.7.1, JSON fixtures, `.cmd` shims dispatching to `.ps1`.

**Reference spec:** `docs/superpowers/specs/2026-05-16-c-integration-tests-mocked-ollama-design.md`

**Branch:** `test/c-integration-mocked-ollama` (already created, spec already committed at `991edd5`).

---

## File Structure

```
c.ps1                                                    # MODIFY: line 21 (CPROMPT_STATE_ROOT hook)
Tests/integration/ollama.cmd                             # CREATE: shim
Tests/integration/ollama-impl.ps1                        # CREATE: stub PowerShell
Tests/integration/claude.cmd                             # CREATE: shim
Tests/integration/claude-impl.ps1                        # CREATE: stub PowerShell
Tests/integration/_helpers.ps1                           # CREATE: Invoke-CIntegration + suite gate
Tests/integration/fixtures/refiner-passthrough.json      # CREATE
Tests/integration/fixtures/refiner-questions.json        # CREATE
Tests/integration/fixtures/compiler-valid-xml.json       # CREATE (compiler-only fixture)
Tests/integration/fixtures/compiler-fallback-nonxml.json # CREATE
Tests/integration/fixtures/combo-passthrough-valid.json  # CREATE (refiner + compiler combined)
Tests/integration/fixtures/combo-questions-valid.json    # CREATE
Tests/c.Integration.Tests.ps1                            # CREATE: 10 It blocks
README.md                                                # MODIFY: one-line note about integration suite (optional, last task)
```

---

## Conventions used in every task

- **Shell:** PowerShell 5.1. Every `Bash`/`PowerShell` command in this plan is for the integration agent's local terminal. Always set `$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'` at the start of a `PowerShell` invocation in this session — the parent process inherits a broken Process PATHEXT.
- **Pester version pin:** `Import-Module Pester -RequiredVersion 5.7.1` before every Pester command, since the machine also has Pester 3.4.0 installed.
- **Commit cadence:** at the end of every task, after green tests. No batching across tasks.
- **Strict mode:** `Set-StrictMode -Version Latest` is on in `c.ps1` and `cprompt.psm1`. The stubs themselves must NOT enable StrictMode (see spec "Stub does NOT set StrictMode").

---

## Task 1: c.ps1 `CPROMPT_STATE_ROOT` hook + smoke

**Files:**
- Modify: `c.ps1:21`

**Why first:** every later task assumes `$TestDrive` isolation works. Land the production-code change with a sanity check before touching test infrastructure.

- [ ] **Step 1: Read the current c.ps1 line 21**

Confirm the line is exactly:
```powershell
$script:StateRoot     = Join-Path $env:USERPROFILE '.cprompt'
```

- [ ] **Step 2: Replace it with the env-hook**

```powershell
$script:StateRoot     = if ($env:CPROMPT_STATE_ROOT) { $env:CPROMPT_STATE_ROOT } else { Join-Path $env:USERPROFILE '.cprompt' }
```

- [ ] **Step 3: Smoke that production behavior is unchanged**

Run:
```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Remove-Item Env:\CPROMPT_STATE_ROOT -ErrorAction SilentlyContinue
& ./c.ps1 -Help; "exit=$LASTEXITCODE"
```
Expected: usage banner printed, `exit=0`. The "estado local: ..." line still says `C:\Users\<user>\.cprompt`.

- [ ] **Step 4: Smoke that the override works**

Run:
```powershell
$env:CPROMPT_STATE_ROOT = "$env:TEMP\cprompt-smoke-$([guid]::NewGuid())"
& ./c.ps1 -Help
Remove-Item Env:\CPROMPT_STATE_ROOT
```
Expected: the "estado local:" line in the usage banner now points to the temp path.

- [ ] **Step 5: Run the full Pester sweep**

Run:
```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests
```
Expected: 202/0 (no regression).

- [ ] **Step 6: Commit**

```powershell
git add c.ps1
git commit -m "feat(c): CPROMPT_STATE_ROOT env hook for test state isolation

One-line hook on c.ps1:21. Unset in production (default to \$env:USERPROFILE\.cprompt).
Integration tests will set it to point under \$TestDrive."
```

---

## Task 2: ollama stub (cmd shim + ps1 impl) + bare smoke

**Files:**
- Create: `Tests/integration/ollama.cmd`
- Create: `Tests/integration/ollama-impl.ps1`

**Why next:** the stub is the foundation for every test case. Validate it standalone with a manual fixture before plumbing it through Pester.

- [ ] **Step 1: Create `Tests/integration/ollama.cmd`**

```cmd
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ollama-impl.ps1" %*
exit /b %ERRORLEVEL%
```

- [ ] **Step 2: Create `Tests/integration/ollama-impl.ps1`**

```powershell
# Test stub for `ollama run [--nowordwrap] <model>`. Reads stdin (discards),
# parses model from $args, increments invocation counter, writes fixture payload.
# Strict mode intentionally OFF — `@()[-1]` would throw under StrictMode Latest.

[Console]::In.ReadToEnd() | Out-Null

$filtered = @($args | Where-Object { $_ -ne 'run' -and $_ -notlike '--*' })
if ($filtered.Count -eq 0) {
    [Console]::Error.WriteLine("stub: no model arg in: $($args -join ' ')")
    exit 1
}
$model = $filtered[-1]

if ($env:CPROMPT_TEST_INVOCATIONS) {
    Add-Content -LiteralPath $env:CPROMPT_TEST_INVOCATIONS -Value $model -Encoding UTF8
}

if (-not $env:CPROMPT_TEST_FIXTURE) {
    [Console]::Error.WriteLine("stub: CPROMPT_TEST_FIXTURE not set")
    exit 1
}

$raw = Get-Content -LiteralPath $env:CPROMPT_TEST_FIXTURE -Raw -Encoding UTF8
$raw = $raw.TrimStart([char]0xFEFF)
$fixture = $raw | ConvertFrom-Json

if (-not $fixture.PSObject.Properties[$model]) {
    [Console]::Error.WriteLine("stub: model '$model' not in fixture $($env:CPROMPT_TEST_FIXTURE)")
    exit 1
}

[Console]::Out.Write([string]$fixture.$model)
exit 0
```

- [ ] **Step 3: Manual smoke — happy path**

Create a temporary fixture and invoke the shim via cmd:
```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
$tmp = New-TemporaryFile
Set-Content -LiteralPath $tmp.FullName -Value '{"prompt-opt":"<task>hi</task><context>x</context><constraints>y</constraints>"}' -Encoding UTF8
$env:CPROMPT_TEST_FIXTURE = $tmp.FullName
$env:CPROMPT_TEST_INVOCATIONS = "$env:TEMP\inv-smoke.txt"
Remove-Item $env:CPROMPT_TEST_INVOCATIONS -ErrorAction SilentlyContinue
'irrelevant input' | & ./Tests/integration/ollama.cmd run --nowordwrap prompt-opt
"exit=$LASTEXITCODE"
Get-Content $env:CPROMPT_TEST_INVOCATIONS
Remove-Item $tmp, $env:CPROMPT_TEST_INVOCATIONS
Remove-Item Env:\CPROMPT_TEST_FIXTURE, Env:\CPROMPT_TEST_INVOCATIONS
```
Expected: stdout `<task>hi</task><context>x</context><constraints>y</constraints>` (NO trailing newline), `exit=0`, invocations file contains one line: `prompt-opt`.

- [ ] **Step 4: Manual smoke — missing model**

```powershell
$tmp = New-TemporaryFile
Set-Content -LiteralPath $tmp.FullName -Value '{"prompt-opt":"x"}' -Encoding UTF8
$env:CPROMPT_TEST_FIXTURE = $tmp.FullName
'irrelevant' | & ./Tests/integration/ollama.cmd run --nowordwrap prompt-refiner 2>&1
"exit=$LASTEXITCODE"
Remove-Item $tmp
Remove-Item Env:\CPROMPT_TEST_FIXTURE
```
Expected: stderr line `stub: model 'prompt-refiner' not in fixture ...`, `exit=1`.

- [ ] **Step 5: Commit**

```powershell
git add Tests/integration/ollama.cmd Tests/integration/ollama-impl.ps1
git commit -m "test(integration): ollama stub (cmd shim + ps1 impl)

PATH-resolved shim dispatches to ollama-impl.ps1 which drains stdin,
parses model from \$args, appends to CPROMPT_TEST_INVOCATIONS, and
writes CPROMPT_TEST_FIXTURE[model] to stdout via [Console]::Out.Write
(raw, no BOM, no trailing newline)."
```

---

## Task 3: `_helpers.ps1` with `Invoke-CIntegration` + first It block (test #6, -NoRefine)

**Files:**
- Create: `Tests/integration/_helpers.ps1`
- Create: `Tests/integration/fixtures/compiler-valid-xml.json`
- Create: `Tests/c.Integration.Tests.ps1`

**Why test #6 first:** simplest case — only one ollama invocation (compiler), no refiner, no Q&A, no cache complexity. Validates the entire helper plumbing in one shot.

- [ ] **Step 1: Create the compiler-only fixture**

`Tests/integration/fixtures/compiler-valid-xml.json` (save as UTF-8 **no BOM**):
```json
{
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>"
}
```

- [ ] **Step 2: Create `Tests/integration/_helpers.ps1`**

```powershell
# Helper module for c.ps1 integration tests. Dot-source from BeforeAll.

function Invoke-CIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TestDrive,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Fixture,
        [string[]]$Args = @(),
        [string[]]$Stubs = @('ollama'),
        [string]$StdIn = ''
    )

    # Stage requested stubs into per-test bin dir.
    $binDir = Join-Path $TestDrive 'bin'
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    foreach ($name in $Stubs) {
        $src1 = Join-Path $RepoRoot "Tests/integration/$name.cmd"
        $src2 = Join-Path $RepoRoot "Tests/integration/$name-impl.ps1"
        Copy-Item -LiteralPath $src1 -Destination (Join-Path $binDir "$name.cmd") -Force
        Copy-Item -LiteralPath $src2 -Destination (Join-Path $binDir "$name-impl.ps1") -Force
    }

    # Per-test scratch paths.
    $stateRoot      = Join-Path $TestDrive 'cprompt-state'
    $invocationsPath = Join-Path $TestDrive 'invocations.txt'
    Set-Content -LiteralPath $invocationsPath -Value '' -Encoding UTF8

    $stdInTmp  = Join-Path $TestDrive 'stdin.txt'
    $stdOutTmp = Join-Path $TestDrive 'stdout.txt'
    $stdErrTmp = Join-Path $TestDrive 'stderr.txt'
    Set-Content -LiteralPath $stdInTmp -Value $StdIn -Encoding UTF8 -NoNewline

    $savedPath = $env:Path
    $savedFixture = $env:CPROMPT_TEST_FIXTURE
    $savedInv = $env:CPROMPT_TEST_INVOCATIONS
    $savedRoot = $env:CPROMPT_STATE_ROOT
    try {
        $env:Path = "$binDir;$env:Path"
        $env:CPROMPT_TEST_FIXTURE = $Fixture
        $env:CPROMPT_TEST_INVOCATIONS = $invocationsPath
        $env:CPROMPT_STATE_ROOT = $stateRoot

        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'c.ps1')) + $Args
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
            -RedirectStandardInput $stdInTmp `
            -RedirectStandardOutput $stdOutTmp `
            -RedirectStandardError $stdErrTmp `
            -Wait -PassThru -NoNewWindow
    } finally {
        $env:Path = $savedPath
        if ($null -ne $savedFixture) { $env:CPROMPT_TEST_FIXTURE = $savedFixture } else { Remove-Item Env:\CPROMPT_TEST_FIXTURE -ErrorAction SilentlyContinue }
        if ($null -ne $savedInv) { $env:CPROMPT_TEST_INVOCATIONS = $savedInv } else { Remove-Item Env:\CPROMPT_TEST_INVOCATIONS -ErrorAction SilentlyContinue }
        if ($null -ne $savedRoot) { $env:CPROMPT_STATE_ROOT = $savedRoot } else { Remove-Item Env:\CPROMPT_STATE_ROOT -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{
        ExitCode     = $p.ExitCode
        StdOut       = if (Test-Path $stdOutTmp) { Get-Content -LiteralPath $stdOutTmp -Raw } else { '' }
        StdErr       = if (Test-Path $stdErrTmp) { Get-Content -LiteralPath $stdErrTmp -Raw } else { '' }
        Invocations  = if (Test-Path $invocationsPath) { Get-Content -LiteralPath $invocationsPath } else { @() }
        StateRoot    = $stateRoot
        HistoryPath  = Join-Path $stateRoot 'history.jsonl'
        CacheDir     = Join-Path $stateRoot 'cache'
        MetricsPath  = Join-Path $stateRoot 'metrics.jsonl'
    }
}

function Assert-PathOrderingGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TestDrive,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    # Stage ollama.cmd, prepend, verify Get-Command resolves to the stub.
    $binDir = Join-Path $TestDrive 'gate-bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot 'Tests/integration/ollama.cmd') (Join-Path $binDir 'ollama.cmd') -Force
    $savedPath = $env:Path
    try {
        $env:Path = "$binDir;$env:Path"
        $resolved = (Get-Command ollama -ErrorAction Stop).Source
        $expected = Join-Path $binDir 'ollama.cmd'
        if ($resolved -ne $expected) {
            throw "PATH ordering gate failed: Get-Command ollama => '$resolved', expected '$expected'. Aborting integration suite."
        }
    } finally {
        $env:Path = $savedPath
    }
}
```

- [ ] **Step 3: Write the failing test (`Tests/c.Integration.Tests.ps1`)**

```powershell
. (Join-Path $PSScriptRoot 'integration/_helpers.ps1')

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Assert-PathOrderingGate -TestDrive $TestDrive -RepoRoot $script:repoRoot
    $script:fixtures = Join-Path $script:repoRoot 'Tests/integration/fixtures'
}

Describe 'c.ps1 -NoRefine (compiler-only)' {
    It 'invokes only the compiler, writes valid XML to stdout, populates state under TestDrive' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-NoRefine','-Raw','sistema ecs unity')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-opt')
        $r.StdOut      | Should -Match '<task>fixture task body</task>'
        Test-Path $r.HistoryPath | Should -BeTrue
        (Get-ChildItem -LiteralPath $r.CacheDir -File).Count | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 4: Run the test — expect FAIL with "file not found" or similar**

Run:
```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: this should actually PASS — Task 2 already created the stub, Step 1 of this task created the fixture, Step 2 created the helper. If it fails, the failure points to a real wiring bug — fix before proceeding.

- [ ] **Step 5: If the test passed, commit**

```powershell
git add Tests/integration/_helpers.ps1 Tests/integration/fixtures/compiler-valid-xml.json Tests/c.Integration.Tests.ps1
git commit -m "test(integration): Invoke-CIntegration helper + first -NoRefine case

- _helpers.ps1: Invoke-CIntegration spawns c.ps1 via Start-Process with
  redirected streams, stages stubs into \$TestDrive/bin per test (so
  test #8 can stage ollama without claude), saves/restores \$env:Path.
- Assert-PathOrderingGate fails fast if Get-Command ollama doesn't
  resolve to the staged stub.
- First It block exercises -NoRefine -Raw: 1 compiler invocation,
  valid XML on stdout, history + cache populated under \$TestDrive."
```

---

## Task 4: Test #1 — refiner passthrough → compiler valid XML

**Files:**
- Create: `Tests/integration/fixtures/combo-passthrough-valid.json`
- Modify: `Tests/c.Integration.Tests.ps1`

- [ ] **Step 1: Create the combo fixture**

`Tests/integration/fixtures/combo-passthrough-valid.json`:
```json
{
  "prompt-refiner": "<passthrough>sistema ecs unity</passthrough>",
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>"
}
```

- [ ] **Step 2: Add the It block to `Tests/c.Integration.Tests.ps1`**

Append after the existing `Describe 'c.ps1 -NoRefine ...'` block:
```powershell
Describe 'c.ps1 refiner passthrough -> compiler' {
    It 'invokes refiner then compiler, both invocations recorded, XML on stdout' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-passthrough-valid.json') `
            -Args @('-Raw','sistema ecs unity')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')
        $r.StdOut      | Should -Match '<task>fixture task body</task>'
        Test-Path $r.HistoryPath | Should -BeTrue
    }
}
```

- [ ] **Step 3: Run the test**

```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 2/0 (previous Task-3 case still green, new case green).

- [ ] **Step 4: Commit**

```powershell
git add Tests/integration/fixtures/combo-passthrough-valid.json Tests/c.Integration.Tests.ps1
git commit -m "test(integration): refiner passthrough -> compiler case"
```

---

## Task 5: Tests #2 + #3 — cache hit on rerun, `-NoCache` forces miss

**Files:**
- Modify: `Tests/c.Integration.Tests.ps1`

- [ ] **Step 1: Add a Describe block with two It blocks**

Append:
```powershell
Describe 'c.ps1 cache behavior' {
    It 'second run with same args serves compiler output from cache (refiner still runs)' {
        $fixture = Join-Path $script:fixtures 'combo-passthrough-valid.json'

        $run1 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('-Raw','sistema ecs unity')
        $run1.ExitCode    | Should -Be 0
        $run1.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        # Re-run with the SAME $TestDrive so cache+invocations carry over.
        $run2 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('-Raw','sistema ecs unity')
        $run2.ExitCode    | Should -Be 0
        # invocations.txt is reset by Invoke-CIntegration at the start of every
        # call (Set-Content ... -Value ''). So run2.Invocations reflects ONLY
        # what happened during run2: refiner ran, compiler served from cache.
        $run2.Invocations | Should -Be @('prompt-refiner')
    }

    It '-NoCache on second run forces compiler call even when cache file exists' {
        $fixture = Join-Path $script:fixtures 'combo-passthrough-valid.json'

        $run1 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('-Raw','sistema ecs unity')
        $run1.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        $run2 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('-NoCache','-Raw','sistema ecs unity')
        $run2.Invocations | Should -Be @('prompt-refiner','prompt-opt')
    }
}
```

- [ ] **Step 2: Run the test**

```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 4/0. If run2 invocations mismatch, check that `$TestDrive` is the same across both `Invoke-CIntegration` calls — Pester scopes `$TestDrive` per `It` block, NOT per `Describe`. **If both runs need shared state, they MUST be in the same `It` block** (which they are above).

- [ ] **Step 3: Commit**

```powershell
git add Tests/c.Integration.Tests.ps1
git commit -m "test(integration): cache hit on rerun, -NoCache forces miss"
```

---

## Task 6: Tests #4 + #5 — refiner questions interactive vs default-skip

**Files:**
- Create: `Tests/integration/fixtures/combo-questions-valid.json`
- Modify: `Tests/c.Integration.Tests.ps1`

- [ ] **Step 1: Create the questions fixture**

`Tests/integration/fixtures/combo-questions-valid.json`:
```json
{
  "prompt-refiner": "<questions><q>qual stack alvo?</q></questions>",
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>"
}
```

- [ ] **Step 2: Add Describe block**

```powershell
Describe 'c.ps1 refiner Q&A flow' {
    It 'with -Interactive and stdin answer, history.input reflects merged answer' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-questions-valid.json') `
            -Args @('-Interactive','-Raw','cache') `
            -StdIn "redis local`n"

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')
        $r.StdOut      | Should -Match '<task>fixture task body</task>'

        $hist = Get-Content -LiteralPath $r.HistoryPath -Raw | ConvertFrom-Json
        $hist.input | Should -Match 'redis local'
        $hist.refined | Should -BeTrue
    }

    It 'without -Interactive (default), refiner questions are skipped and raw input is used' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-questions-valid.json') `
            -Args @('-Raw','cache')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        $hist = Get-Content -LiteralPath $r.HistoryPath -Raw | ConvertFrom-Json
        $hist.input   | Should -Be 'cache'
        $hist.refined | Should -BeFalse

        # The metrics line should record metricMode='questions-skip'.
        $metrics = Get-Content -LiteralPath $r.MetricsPath -Raw | ConvertFrom-Json
        $metrics.mode | Should -Be 'questions-skip'
    }
}
```

- [ ] **Step 3: Run**

```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 6/0. If the `-Interactive` case hangs, the `-RedirectStandardInput` file isn't being closed cleanly — verify `$StdIn` ended with a newline so `Read-Host` completes.

- [ ] **Step 4: Commit**

```powershell
git add Tests/integration/fixtures/combo-questions-valid.json Tests/c.Integration.Tests.ps1
git commit -m "test(integration): refiner Q&A flow (-Interactive answered + default skip)"
```

---

## Task 7: Test #7 — compiler emits non-XML, frictionless fallback

**Files:**
- Create: `Tests/integration/fixtures/compiler-fallback-nonxml.json`
- Modify: `Tests/c.Integration.Tests.ps1`

- [ ] **Step 1: Create the fallback fixture**

`Tests/integration/fixtures/compiler-fallback-nonxml.json`:
```json
{
  "prompt-opt": "sorry, I cannot help with that.\nhere is some prose that does not contain the required tag triple at all."
}
```

- [ ] **Step 2: Add Describe block**

```powershell
Describe 'c.ps1 frictionless fallback' {
    It 'when compiler emits non-XML, c.ps1 emits AVISO and uses raw input as XML payload' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-fallback-nonxml.json') `
            -Args @('-NoRefine','sistema ecs unity')

        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'AVISO: otimizador nao produziu XML valido'

        # Fallback runs are NOT cached (c.ps1:248 comment).
        if (Test-Path $r.CacheDir) {
            (Get-ChildItem -LiteralPath $r.CacheDir -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        $metrics = Get-Content -LiteralPath $r.MetricsPath -Raw | ConvertFrom-Json
        $metrics.mode | Should -Be 'fallback'
    }
}
```

- [ ] **Step 3: Run + commit**

```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 7/0.

```powershell
git add Tests/integration/fixtures/compiler-fallback-nonxml.json Tests/c.Integration.Tests.ps1
git commit -m "test(integration): frictionless fallback when compiler emits non-XML"
```

---

## Task 8: claude stub + Tests #8 + #9 — `-Send` without and with `claude`

**Files:**
- Create: `Tests/integration/claude.cmd`
- Create: `Tests/integration/claude-impl.ps1`
- Modify: `Tests/c.Integration.Tests.ps1`

- [ ] **Step 1: Create `Tests/integration/claude.cmd`**

```cmd
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-impl.ps1" %*
exit /b %ERRORLEVEL%
```

- [ ] **Step 2: Create `Tests/integration/claude-impl.ps1`**

```powershell
# Drain stdin (the XML c.ps1 pipes via `$xml | & claude -p`), ignore all args
# (including -p / --print), record the invocation, write OK to stdout, exit 0.

[Console]::In.ReadToEnd() | Out-Null

if ($env:CPROMPT_TEST_INVOCATIONS) {
    Add-Content -LiteralPath $env:CPROMPT_TEST_INVOCATIONS -Value 'claude' -Encoding UTF8
}

[Console]::Out.Write('OK')
exit 0
```

- [ ] **Step 3: Add Describe block with both It cases**

```powershell
Describe 'c.ps1 -Send' {
    It 'exits 8 with error message when claude is not on PATH' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Send','-NoRefine','sistema ecs unity') `
            -Stubs @('ollama')   # NB: no claude staged

        $r.ExitCode | Should -Be 8
        $r.StdOut   | Should -Match "'claude' CLI nao encontrado"
        $r.Invocations | Should -Not -Contain 'claude'
    }

    It 'with claude on PATH, pipes XML and exits with claude exit code' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Send','-NoRefine','sistema ecs unity') `
            -Stubs @('ollama','claude')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Contain 'claude'
    }
}
```

- [ ] **Step 4: Run**

```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 9/0.

- [ ] **Step 5: Commit**

```powershell
git add Tests/integration/claude.cmd Tests/integration/claude-impl.ps1 Tests/c.Integration.Tests.ps1
git commit -m "test(integration): claude stub + -Send cases (with/without claude on PATH)"
```

---

## Task 9: Test #10 — zero-signal pre-gate with `-Interactive`

**Files:**
- Modify: `Tests/c.Integration.Tests.ps1`

- [ ] **Step 1: Add Describe block**

The zero-signal pre-gate at c.ps1:111-129 fires when `Test-InputIsZeroSignal` returns true (input <4 words). With `-Interactive`, it asks ONE deterministic question and skips the refiner entirely — only the compiler is invoked.

```powershell
Describe 'c.ps1 zero-signal pre-gate' {
    It 'with -Interactive and short input, pre-gate Q runs, refiner is skipped, only compiler invokes' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Interactive','-Raw','cache') `
            -StdIn "area backend, problema slow query, stack postgres`n"

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-opt')   # refiner SKIPPED by pre-gate
        $r.StdOut      | Should -Match '<task>fixture task body</task>'

        $hist = Get-Content -LiteralPath $r.HistoryPath -Raw | ConvertFrom-Json
        $hist.input | Should -Match 'postgres'
        $hist.refined | Should -BeTrue

        $metrics = Get-Content -LiteralPath $r.MetricsPath -Raw | ConvertFrom-Json
        $metrics.mode | Should -Be 'pregate'
    }
}
```

- [ ] **Step 2: Run + commit**

```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 10/0.

```powershell
git add Tests/c.Integration.Tests.ps1
git commit -m "test(integration): zero-signal pre-gate with -Interactive answered"
```

---

## Task 10: Full sweep, optional README note, push, PR

**Files:**
- Modify: `README.md` (optional)

- [ ] **Step 1: Run full Pester sweep**

```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests
```
Expected: 212/0 (202 prior + 10 new). If any prior test regressed, stop and investigate before pushing.

- [ ] **Step 2: Smoke `c.ps1 -Help` one more time**

```powershell
& ./c.ps1 -Help; "exit=$LASTEXITCODE"
```
Expected: usage banner, `exit=0`.

- [ ] **Step 3: (Optional) Append a one-line note to README**

If README has a "Tests" section, add under it:
```markdown
- `Tests/c.Integration.Tests.ps1` — subprocess integration tests for `c.ps1` using a PATH-shim ollama stub. Runs without a real ollama install.
```

Commit if changed:
```powershell
git add README.md
git commit -m "docs(readme): note integration test suite"
```

- [ ] **Step 4: Push branch**

```powershell
git push -u origin test/c-integration-mocked-ollama
```

- [ ] **Step 5: Open PR**

```powershell
$env:PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
gh pr create --base main --head test/c-integration-mocked-ollama --title "test(c): subprocess integration coverage with mocked ollama" --body @'
## Summary

- Adds 10 Pester 5 integration tests for `c.ps1` covering refiner→compiler happy path, cache hit/miss, Q&A loop (`-Interactive` answered + default skip), `-NoRefine`, frictionless fallback, `-Send` with/without `claude`, and zero-signal pre-gate.
- Mocks ollama (and claude) via a PATH-shim: `Tests/integration/ollama.cmd` dispatches to `ollama-impl.ps1`, which serves JSON fixtures keyed by model name.
- One production change: `c.ps1:21` reads `$env:CPROMPT_STATE_ROOT` when set, falling back to `$env:USERPROFILE\.cprompt` otherwise — unset in production, no behavior change.

## Why

Closes deferred follow-up #5 from the project state memory: the refiner→compiler flow, cache hit/miss, Q&A loop, and `-Send`-claude-missing paths were untested end-to-end. Bugs that span pipeline boundaries (e.g., PR #20's dead `-Send` guard) escape unit coverage.

## Test plan

- [x] `Invoke-Pester ./Tests/c.Integration.Tests.ps1` → 10/0.
- [x] `Invoke-Pester ./Tests` full sweep → 212/0.
- [x] Smoke `c.ps1 -Help` exit 0, usage banner intact.
- [x] PATH-ordering gate in `BeforeAll` confirms `Get-Command ollama` resolves to the stub before any It runs.

Design: `docs/superpowers/specs/2026-05-16-c-integration-tests-mocked-ollama-design.md`
Plan: `docs/superpowers/plans/2026-05-16-c-integration-tests-mocked-ollama.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
'@
```

Record the PR URL. Update `project_resume_state.md` memory to mark follow-up #5 as "fixed-pending-merge" pointing at this PR.

---

## Self-review checklist (run after writing the plan)

- [ ] Spec coverage — every section in `2026-05-16-c-integration-tests-mocked-ollama-design.md` maps to a task: env hook (Task 1), ollama stub (Task 2), helper + PATH-gate (Task 3), 10 test cases (Tasks 3–9), claude stub (Task 8), README + PR (Task 10). ✔
- [ ] Placeholder scan — no "TBD", no "add appropriate X", no "similar to Task N". Every code block is complete. ✔
- [ ] Type consistency — `Invoke-CIntegration` parameter names (`-TestDrive`, `-RepoRoot`, `-Fixture`, `-Args`, `-Stubs`, `-StdIn`) match across every test task; return-object properties (`ExitCode`, `StdOut`, `StdErr`, `Invocations`, `HistoryPath`, `CacheDir`, `MetricsPath`, `StateRoot`) referenced consistently. ✔
- [ ] Env var names (`CPROMPT_STATE_ROOT`, `CPROMPT_TEST_FIXTURE`, `CPROMPT_TEST_INVOCATIONS`) match across spec, helper, stubs, and tests. ✔
