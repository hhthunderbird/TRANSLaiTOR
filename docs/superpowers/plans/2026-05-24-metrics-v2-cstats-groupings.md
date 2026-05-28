# Metrics v2 — cstats -Since / -By Groupings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add time-based filtering (`-Since`) and field-based grouping (`-By mode|model`) to cstats.

**Architecture:** New `ConvertTo-SinceDate` function in cprompt.psm1 parses relative (`7d`, `24h`, `1w`) and absolute ISO-8601 date strings. cstats.ps1 gains `-Since` and `-By` parameters. `-Since` filters entries before `-Last`. `-By` groups entries and runs `Get-MetricsSummary` per group with a per-group display block. Display logic extracted into `Write-MetricsSummary` function to avoid duplication between single and grouped modes.

**Tech Stack:** PowerShell 5.1, Pester 5.7.1

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `cprompt.psm1` | Modify | Add `ConvertTo-SinceDate` function + export |
| `Tests/cprompt.Tests.ps1` | Modify | Unit tests for `ConvertTo-SinceDate` |
| `cstats.ps1` | Modify | Add `-Since`/`-By` params, extract `Write-MetricsSummary`, filtering + grouping logic |
| `Tests/cstats.Tests.ps1` | Create | Script-level tests for filtering, grouping, validation, composability |

---

### Task 1: Create feature branch

- [ ] **Step 1: Create and switch to feature branch**

```powershell
git checkout -b feat/metrics-v2-cstats-groupings
```

---

### Task 2: ConvertTo-SinceDate — failing tests

**Files:**
- Modify: `Tests/cprompt.Tests.ps1` (add new Describe block at end of file)

- [ ] **Step 1: Add Describe block for ConvertTo-SinceDate**

Add after the last `Describe` block (after `Describe 'Get-MetricsSummary Claude usage aggregation'`):

```powershell
Describe 'ConvertTo-SinceDate' {
    It 'parses relative durations: 7d, 24h, 1w' {
        $now = [datetime]::Now
        $d7 = ConvertTo-SinceDate '7d'
        [math]::Abs(($d7 - $now.AddDays(-7)).TotalSeconds) | Should -BeLessThan 2

        $h24 = ConvertTo-SinceDate '24h'
        [math]::Abs(($h24 - $now.AddHours(-24)).TotalSeconds) | Should -BeLessThan 2

        $w1 = ConvertTo-SinceDate '1w'
        [math]::Abs(($w1 - $now.AddDays(-7)).TotalSeconds) | Should -BeLessThan 2
    }

    It 'is case-insensitive on the unit suffix' {
        $now = [datetime]::Now
        $upper = ConvertTo-SinceDate '7D'
        [math]::Abs(($upper - $now.AddDays(-7)).TotalSeconds) | Should -BeLessThan 2
    }

    It 'parses absolute ISO-8601 date and datetime' {
        $dateOnly = ConvertTo-SinceDate '2026-05-01'
        $dateOnly.Year  | Should -Be 2026
        $dateOnly.Month | Should -Be 5
        $dateOnly.Day   | Should -Be 1

        $dateTime = ConvertTo-SinceDate '2026-05-01T14:00:00'
        $dateTime.Hour | Should -Be 14
    }

    It 'returns $null on invalid input' {
        $result = ConvertTo-SinceDate 'garbage' -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }

    It 'trims whitespace from input' {
        $now = [datetime]::Now
        $result = ConvertTo-SinceDate '  7d  '
        [math]::Abs(($result - $now.AddDays(-7)).TotalSeconds) | Should -BeLessThan 2
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*ConvertTo-SinceDate*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 5 tests FAIL (function not found).

- [ ] **Step 3: Commit**

```powershell
git add Tests/cprompt.Tests.ps1
git commit -m "test(parser): add failing tests for ConvertTo-SinceDate"
```

---

### Task 3: Implement ConvertTo-SinceDate + export

**Files:**
- Modify: `cprompt.psm1` (add function before `Test-InputAcceptable`, add to Export-ModuleMember)

- [ ] **Step 1: Add ConvertTo-SinceDate function**

Insert before the `function Test-InputAcceptable` definition in cprompt.psm1:

```powershell
function ConvertTo-SinceDate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $Value = $Value.Trim()

    if ($Value -match '^\d+([hdw])$') {
        $num = [int]($Value -replace '[hdw]$','')
        switch ($Matches[1]) {
            'h' { return [datetime]::Now.AddHours(-$num) }
            'd' { return [datetime]::Now.AddDays(-$num) }
            'w' { return [datetime]::Now.AddDays(-$num * 7) }
        }
    }

    $parsed = $null
    if ([datetime]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    Write-Error "Invalid -Since value: '$Value'. Use relative (7d, 24h, 1w) or ISO-8601 (2026-05-01)."
    return $null
}
```

Key points:
- `-match` is case-insensitive in PowerShell — `7D`, `24H`, `1W` all match
- `switch` is case-insensitive in PowerShell — handles mixed-case `$Matches[1]`
- `[datetime]::TryParse` doesn't throw — returns bool, safe for invalid input
- `Write-Error` only fires for truly invalid input; callers use `-ErrorAction SilentlyContinue`
- `[CmdletBinding()]` enables `-ErrorAction` parameter support

- [ ] **Step 2: Add to Export-ModuleMember**

Find the `Export-ModuleMember -Function` block and add `ConvertTo-SinceDate` after `ConvertFrom-OllamaVerboseStats`:

```powershell
    ConvertFrom-OllamaVerboseStats, `
    ConvertTo-SinceDate, `
```

- [ ] **Step 3: Run tests**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*ConvertTo-SinceDate*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 5 tests PASS.

- [ ] **Step 4: Commit**

```powershell
git add cprompt.psm1
git commit -m "feat(parser): add ConvertTo-SinceDate for relative and absolute date parsing"
```

---

### Task 4: Refactor cstats.ps1 — add -Since/-By params, extract display, implement filtering and grouping

**Files:**
- Modify: `cstats.ps1` (full rewrite preserving behavior for existing params)

- [ ] **Step 1: Replace cstats.ps1 with refactored version**

Replace the entire content of `cstats.ps1` with:

```powershell
[CmdletBinding()]
param(
    [int]$Last = 0,
    [string]$Since,
    [string]$By,
    [string]$Path = (Join-Path $env:USERPROFILE '.cprompt/metrics.jsonl')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path $here 'cprompt.psm1'
Remove-Module cprompt -ErrorAction SilentlyContinue
Import-Module $module -Force

function Write-MetricsSummary {
    param($summary)
    Write-Host ("Cache hits   : {0:P1}" -f $summary.CacheHitRate)
    Write-Host ("p50 totalMs  : {0}" -f $summary.LatencyP50)
    Write-Host ("p95 totalMs  : {0}" -f $summary.LatencyP95)
    Write-Host ("Avg xml/input: {0:N2}" -f $summary.AvgCompressionRatio)
    if ($summary.CompilerEvalCountMedian -gt 0) {
        Write-Host ("Compiler eval/s p50: {0:N2}" -f $summary.CompilerEvalRateP50)
        Write-Host ("Compiler eval/s p95: {0:N2}" -f $summary.CompilerEvalRateP95)
        Write-Host ("Compiler tokens out (median): {0}" -f $summary.CompilerEvalCountMedian)
    }
    if ($summary.ColdStartCount -gt 0) {
        Write-Host ("Cold starts      : {0}/{1} ({2:P1})" -f $summary.ColdStartCount, $summary.Count, $summary.ColdStartRate)
    }
    if ($summary.ClaudeSendCount -gt 0) {
        Write-Host ("Claude sends     : {0}" -f $summary.ClaudeSendCount)
        Write-Host ("Claude cost total: `${0:N2}" -f $summary.ClaudeCostTotal)
        Write-Host ("Claude cost avg  : `${0:N2}" -f $summary.ClaudeCostAvg)
        Write-Host ("Claude tokens avg: {0} out / {1} in" -f $summary.ClaudeAvgOutputTokens, $summary.ClaudeAvgInputTokens)
    }
    Write-Host ''
    Write-Host 'Mode counts:'
    foreach ($m in ($summary.ModeCounts.Keys | Sort-Object)) {
        Write-Host ("  {0,-12} {1}" -f $m, $summary.ModeCounts[$m])
    }
}

# --- load and filter entries ---
$entries = @(Read-MetricsFile -Path $Path)

if ($Since) {
    $sinceDate = ConvertTo-SinceDate $Since -ErrorAction SilentlyContinue
    if ($null -eq $sinceDate) {
        Write-Host "ERRO: Invalid -Since value '$Since'. Use relative (7d, 24h, 1w) or ISO-8601 (2026-05-01)." -ForegroundColor Red
        exit 1
    }
    $entries = @($entries | Where-Object { [datetime]$_.ts -ge $sinceDate })
}

if ($Last -gt 0 -and $entries.Count -gt $Last) {
    $entries = $entries[($entries.Count - $Last)..($entries.Count - 1)]
}

Write-Host "Metrics file : $Path"
Write-Host "Entries      : $($entries.Count)"
if ($entries.Count -eq 0) { return }

# --- display ---
if ($By) {
    if ($By -notin @('mode','model')) {
        Write-Host "ERRO: Invalid -By value '$By'. Use 'mode' or 'model'." -ForegroundColor Red
        exit 1
    }
    $hasField = {
        param($obj, $name)
        if ($obj -is [hashtable]) { return $obj.ContainsKey($name) }
        return $null -ne $obj.PSObject.Properties[$name]
    }
    $groups = [ordered]@{}
    foreach ($e in $entries) {
        $key = if (& $hasField $e $By) { [string]$e.$By } else { '(unknown)' }
        if (-not $key) { $key = '(unknown)' }
        if (-not $groups.Contains($key)) { $groups[$key] = [System.Collections.ArrayList]@() }
        [void]$groups[$key].Add($e)
    }
    foreach ($key in ($groups.Keys | Sort-Object { $groups[$_].Count } -Descending)) {
        $groupEntries = @($groups[$key])
        Write-Host ''
        Write-Host "=== ${By}: $key ($($groupEntries.Count) entries) ==="
        $s = Get-MetricsSummary -Entries $groupEntries
        Write-MetricsSummary $s
    }
} else {
    $summary = Get-MetricsSummary -Entries $entries
    Write-MetricsSummary $summary
}
```

Key changes from original:
- New `-Since` and `-By` parameters
- Display logic extracted into `Write-MetricsSummary` function (DRY)
- `-Since` filtering applied BEFORE `-Last` (spec requirement)
- `-By` validation: only `mode` and `model` accepted, exit 1 on invalid
- `$hasField` helper duplicated from `Get-MetricsSummary` (4 lines, avoids expanding module surface)
- Missing-field entries grouped into `(unknown)`
- Groups sorted by entry count descending (spec requirement)
- Existing behavior unchanged when no `-Since`/`-By` are passed

- [ ] **Step 2: Smoke test — verify existing behavior unchanged**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
powershell.exe -NoProfile -File cstats.ps1 -Last 5
```

Expected: Same output format as before. No errors.

- [ ] **Step 3: Commit**

```powershell
git add cstats.ps1
git commit -m "feat(cstats): add -Since/-By params, extract Write-MetricsSummary, implement filtering and grouping"
```

---

### Task 5: Create cstats tests

**Files:**
- Create: `Tests/cstats.Tests.ps1`

- [ ] **Step 1: Create test file with helper and fixture**

Create `Tests/cstats.Tests.ps1`:

```powershell
BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
}

function Invoke-Cstats {
    param(
        [string[]]$CstatsArgs
    )
    $stdOutTmp = Join-Path $TestDrive 'cstats-stdout.txt'
    $stdErrTmp = Join-Path $TestDrive 'cstats-stderr.txt'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $script:repoRoot 'cstats.ps1')) + $CstatsArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
        -RedirectStandardOutput $stdOutTmp `
        -RedirectStandardError $stdErrTmp `
        -Wait -PassThru -NoNewWindow
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = if (Test-Path $stdOutTmp) { Get-Content -LiteralPath $stdOutTmp -Raw } else { '' }
        StdErr   = if (Test-Path $stdErrTmp) { Get-Content -LiteralPath $stdErrTmp -Raw } else { '' }
    }
}

function New-TestMetrics {
    $metricsPath = Join-Path $TestDrive 'test-metrics.jsonl'
    @(
        '{"ts":"2026-05-15T10:00:00.0000000Z","mode":"refiner","model":"prompt-opt","totalMs":3000,"inputChars":100,"xmlChars":300}'
        '{"ts":"2026-05-20T10:00:00.0000000Z","mode":"raw","model":"prompt-opt","totalMs":2000,"inputChars":80,"xmlChars":200}'
        '{"ts":"2026-05-23T10:00:00.0000000Z","mode":"refiner","model":"prompt-refiner","totalMs":4000,"inputChars":120,"xmlChars":350}'
        '{"ts":"2026-05-24T10:00:00.0000000Z","mode":"cache","totalMs":500,"inputChars":50,"xmlChars":150}'
    ) | Set-Content -LiteralPath $metricsPath -Encoding UTF8
    return $metricsPath
}

Describe 'cstats.ps1 -Since filtering' {
    It 'filters entries by absolute ISO-8601 date' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-Since','2026-05-22','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'Entries\s*:\s*2'
    }
}

Describe 'cstats.ps1 -By grouping' {
    It 'groups by mode with headers sorted by count descending' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-By','mode','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match '=== mode: refiner \(2 entries\) ==='
        $r.StdOut   | Should -Match '=== mode: raw \(1 entries\) ==='
        $r.StdOut   | Should -Match '=== mode: cache \(1 entries\) ==='
    }

    It 'groups by model with (unknown) for entries missing the field' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-By','model','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match '=== model: prompt-opt \(2 entries\) ==='
        $r.StdOut   | Should -Match '=== model: prompt-refiner \(1 entries\) ==='
        $r.StdOut   | Should -Match '=== model: \(unknown\) \(1 entries\) ==='
    }

    It 'exits 1 on invalid -By value' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-By','invalid','-Path',$metricsPath)
        $r.ExitCode | Should -Be 1
    }
}

Describe 'cstats.ps1 composability' {
    It '-Since applied before -Last' {
        $metricsPath = New-TestMetrics
        # -Since 2026-05-19 filters to 3 entries (May 20, 23, 24), -Last 2 takes last 2 (May 23, 24)
        $r = Invoke-Cstats -CstatsArgs @('-Since','2026-05-19','-Last','2','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'Entries\s*:\s*2'
    }

    It '-Since + -By filters then groups' {
        $metricsPath = New-TestMetrics
        # -Since 2026-05-22 filters to 2 entries (May 23 refiner, May 24 cache)
        $r = Invoke-Cstats -CstatsArgs @('-Since','2026-05-22','-By','mode','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'Entries\s*:\s*2'
        $r.StdOut   | Should -Match '=== mode: refiner \(1 entries\) ==='
        $r.StdOut   | Should -Match '=== mode: cache \(1 entries\) ==='
        $r.StdOut   | Should -Not -Match '=== mode: raw'
    }
}
```

- [ ] **Step 2: Run cstats tests**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/cstats.Tests.ps1'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 5 tests PASS.

- [ ] **Step 3: Commit**

```powershell
git add Tests/cstats.Tests.ps1
git commit -m "test(cstats): add tests for -Since filtering, -By grouping, and composability"
```

---

### Task 6: Full test suite + pre-push audit + push + PR

- [ ] **Step 1: Run full Pester test suite**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests -Output Detailed
```

Expected: All tests PASS (241 existing + 10 new = 251, 0 failures).

- [ ] **Step 2: Review diff against main**

Run:
```powershell
git diff main...HEAD --stat
git diff main...HEAD
```

Verify:
- `cprompt.psm1`: `ConvertTo-SinceDate` function + export
- `Tests/cprompt.Tests.ps1`: 5 unit tests for `ConvertTo-SinceDate`
- `cstats.ps1`: `-Since`/`-By` params, `Write-MetricsSummary` extraction, filtering + grouping
- `Tests/cstats.Tests.ps1`: 5 script-level tests (new file)
- No unrelated changes

- [ ] **Step 3: Push and create PR**

```powershell
git push -u origin feat/metrics-v2-cstats-groupings
```

```powershell
gh pr create --title "feat: add -Since and -By grouping to cstats" --body @'
## Summary
- New `ConvertTo-SinceDate` function: relative (`7d`, `24h`, `1w`) and absolute ISO-8601
- `-Since` filters entries by timestamp, applied before `-Last`
- `-By mode|model` groups entries, displays per-group summary sorted by count
- Missing-field entries grouped into `(unknown)`
- Extract `Write-MetricsSummary` to DRY single vs grouped display
- Composability: `-Since 7d -By mode -Last 50` all compose correctly

## Test plan
- [x] `Invoke-Pester ./Tests` — all 251 tests pass
- [ ] `cstats -Since 7d` — filters to last week
- [ ] `cstats -By mode` — grouped output with headers
- [ ] `cstats -Since 24h -By model` — filter then group
- [ ] `cstats -By invalid` — error + exit 1

🤖 Generated with [Claude Code](https://claude.com/claude-code)
'@
```
