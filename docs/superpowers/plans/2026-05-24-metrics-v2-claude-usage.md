# Metrics v2 — Claude API Token Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture Claude CLI token usage, cost, and model data when `-Send` is used, and surface it in metrics summary and cstats.

**Architecture:** Change `claude -p` to `claude -p --output-format json` in c.ps1. Parse JSON response for `.result` (display), `.usage`/`.total_cost_usd`/`.modelUsage` (metrics). Defer `Add-MetricEntry` for `-Send` path so `claudeUsage` can be appended. Graceful fallback when JSON parse fails (show raw text, skip usage). Extend `Get-MetricsSummary` with aggregate Claude usage fields. Display in cstats when data exists.

**Tech Stack:** PowerShell 5.1, Pester 5.7.1, Claude CLI `--output-format json`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Tests/integration/claude-impl.ps1` | Modify | Detect `--output-format json` → emit JSON fixture; support `CPROMPT_TEST_CLAUDE_BAD_JSON` env var for malformed output |
| `c.ps1:271-320` | Modify | Restructure `-Send` block for JSON capture; reorder metrics write timing |
| `Tests/c.Integration.Tests.ps1:154-179` | Modify | Add integration tests for JSON capture + bad-JSON fallback; extend existing Send test |
| `cprompt.psm1` (Get-MetricsSummary) | Modify | Add `ClaudeSendCount`, `ClaudeCostTotal`, `ClaudeCostAvg`, `ClaudeAvgInputTokens`, `ClaudeAvgOutputTokens` |
| `Tests/cprompt.Tests.ps1` | Modify | Summary unit tests for Claude usage fields |
| `cstats.ps1` | Modify | Display Claude usage stats when `ClaudeSendCount > 0` |

---

### Task 1: Create feature branch

- [ ] **Step 1: Create and switch to feature branch**

```powershell
git checkout -b feat/metrics-v2-claude-usage
```

- [ ] **Step 2: Verify branch**

Run: `git branch --show-current`
Expected: `feat/metrics-v2-claude-usage`

---

### Task 2: Update claude test stub — JSON output + bad-JSON mode

**Files:**
- Modify: `Tests/integration/claude-impl.ps1`

- [ ] **Step 1: Replace claude-impl.ps1 content**

The stub must: (a) detect `--output-format` in args and emit JSON, (b) support `CPROMPT_TEST_CLAUDE_BAD_JSON` env var for malformed output, (c) still record invocations.

Replace the entire file with:

```powershell
# Test stub for `claude` CLI. Drains stdin, records invocation, exits 0.
# When --output-format json is detected, emits a JSON response matching
# Claude CLI's actual output shape. When CPROMPT_TEST_CLAUDE_BAD_JSON=1,
# emits malformed output to test the fallback path.

[Console]::In.ReadToEnd() | Out-Null

if ($env:CPROMPT_TEST_INVOCATIONS) {
    Add-Content -LiteralPath $env:CPROMPT_TEST_INVOCATIONS -Value 'claude' -Encoding UTF8
}

$hasJsonFlag = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--output-format' -and ($i + 1) -lt $args.Count -and $args[$i + 1] -eq 'json') {
        $hasJsonFlag = $true
        break
    }
}

if ($hasJsonFlag) {
    if ($env:CPROMPT_TEST_CLAUDE_BAD_JSON -eq '1') {
        [Console]::Out.Write('NOT_JSON_OUTPUT')
    } else {
        $json = '{"result":"stub-claude-answer","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2},"total_cost_usd":0.001,"duration_ms":1500,"modelUsage":{"claude-sonnet-4-6":{"costUSD":0.001,"input_tokens":10,"output_tokens":5}}}'
        [Console]::Out.Write($json)
    }
} else {
    [Console]::Out.Write('OK')
}

exit 0
```

- [ ] **Step 2: Verify existing -Send tests still pass (stub backward compat)**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/c.Integration.Tests.ps1'
$cfg.Filter.FullName = '*-Send*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: Both existing -Send tests PASS. The stub now emits JSON when `--output-format json` is passed, but c.ps1 still calls `claude -p` (without the flag), so the stub emits plain "OK" and everything works as before.

- [ ] **Step 3: Commit**

```powershell
git add Tests/integration/claude-impl.ps1
git commit -m "test(stub): update claude stub to emit JSON for --output-format json"
```

---

### Task 3: Write failing integration tests — claudeUsage capture + bad-JSON fallback

**Files:**
- Modify: `Tests/c.Integration.Tests.ps1` (inside existing `Describe 'c.ps1 -Send'` block)

- [ ] **Step 1: Add test for claudeUsage in metrics entry**

Add this `It` block inside the existing `Describe 'c.ps1 -Send'` block, after the last `It`:

```powershell
    It 'captures claudeUsage in metrics entry when claude returns JSON' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Send','-NoRefine','sistema ecs unity') `
            -Stubs @('ollama','claude')

        $r.ExitCode | Should -Be 0

        $lines = @(Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_ -and $_.Trim() })
        $entry = $lines[-1] | ConvertFrom-Json
        $entry.claudeUsage                        | Should -Not -BeNullOrEmpty
        [int]$entry.claudeUsage.inputTokens       | Should -Be 10
        [int]$entry.claudeUsage.outputTokens      | Should -Be 5
        [int]$entry.claudeUsage.cacheReadTokens   | Should -Be 3
        [int]$entry.claudeUsage.cacheCreationTokens | Should -Be 2
        [double]$entry.claudeUsage.costUsd        | Should -Be 0.001
        [int]$entry.claudeUsage.durationMs        | Should -Be 1500
        $entry.claudeUsage.model                  | Should -Be 'claude-sonnet-4-6'
    }
```

- [ ] **Step 2: Add test for bad-JSON fallback**

Add this `It` block after the previous one:

```powershell
    It 'writes metrics without claudeUsage when claude returns non-JSON' {
        $savedBadJson = $env:CPROMPT_TEST_CLAUDE_BAD_JSON
        try {
            $env:CPROMPT_TEST_CLAUDE_BAD_JSON = '1'
            $r = Invoke-CIntegration `
                -TestDrive $TestDrive `
                -RepoRoot $script:repoRoot `
                -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
                -Args @('-Send','-NoRefine','sistema ecs unity') `
                -Stubs @('ollama','claude')
        } finally {
            if ($null -ne $savedBadJson) { $env:CPROMPT_TEST_CLAUDE_BAD_JSON = $savedBadJson }
            else { Remove-Item Env:\CPROMPT_TEST_CLAUDE_BAD_JSON -ErrorAction SilentlyContinue }
        }

        $r.ExitCode | Should -Be 0

        $lines = @(Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_ -and $_.Trim() })
        $entry = $lines[-1] | ConvertFrom-Json
        $entry.PSObject.Properties['claudeUsage'] | Should -BeNullOrEmpty
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/c.Integration.Tests.ps1'
$cfg.Filter.FullName = '*-Send*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: 2 new tests FAIL (c.ps1 doesn't yet parse JSON or write claudeUsage). 2 existing -Send tests PASS.

- [ ] **Step 4: Commit failing tests**

```powershell
git add Tests/c.Integration.Tests.ps1
git commit -m "test(integration): add failing tests for claudeUsage capture and bad-JSON fallback"
```

---

### Task 4: Restructure c.ps1 -Send block — JSON capture + metrics write reorder

**Files:**
- Modify: `c.ps1:271-320`

The key change: for `-Send` path, defer `Add-MetricEntry` until after the claude call so `claudeUsage` can be appended. For non-Send paths, write metrics at current location (no change in timing).

- [ ] **Step 1: Modify metrics write to conditionally defer for -Send**

In c.ps1, find the `Add-MetricEntry` call inside the try block (currently at line 295). Replace just that one line with a conditional:

Current line 295:
```powershell
    Add-MetricEntry -Path $metricsPath -Entry $entry
```

Replace with:
```powershell
    if (-not $Send) {
        Add-MetricEntry -Path $metricsPath -Entry $entry
    }
```

This defers metrics writing for the -Send path. The `$entry` hashtable remains available in the outer scope for later mutation.

- [ ] **Step 2: Restructure the -Send block for JSON capture**

Replace the entire `-Send` block (lines 307-320) with:

```powershell
if ($Send) {
    if (-not (Test-CommandPresent -Name 'claude')) {
        Write-Host "ERRO: 'claude' CLI nao encontrado no PATH. XML copiado para clipboard como fallback." -ForegroundColor Red
        $xml | Set-Clipboard
        if ($null -ne $entry) {
            try { Add-MetricEntry -Path $metricsPath -Entry $entry } catch {}
        }
        exit 8
    }
    Write-Host "--- enviando para claude CLI ---" -ForegroundColor Cyan
    $claudeRaw  = $xml | & claude -p --output-format json
    $claudeExit = $LASTEXITCODE
    $claudeUsage = $null
    try {
        $claudeObj  = $claudeRaw | ConvertFrom-Json
        $claudeText = $claudeObj.result
        $claudeUsage = @{
            inputTokens         = [int]$claudeObj.usage.input_tokens
            outputTokens        = [int]$claudeObj.usage.output_tokens
            cacheReadTokens     = [int]$claudeObj.usage.cache_read_input_tokens
            cacheCreationTokens = [int]$claudeObj.usage.cache_creation_input_tokens
            costUsd             = [double]$claudeObj.total_cost_usd
            durationMs          = [int]$claudeObj.duration_ms
            model               = $claudeObj.modelUsage.PSObject.Properties[0].Name
        }
    } catch {
        $claudeText  = $claudeRaw
        $claudeUsage = $null
        Write-Warning "Could not parse Claude JSON output; token usage not captured."
    }
    if ($null -ne $entry) {
        if ($claudeUsage) { $entry.claudeUsage = $claudeUsage }
        try { Add-MetricEntry -Path $metricsPath -Entry $entry } catch {}
    }
    Write-Output $claudeText
    exit $claudeExit
} else {
    $xml | Set-Clipboard
    Write-Host "copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude." -ForegroundColor Green
}
```

Key points:
- `Write-Output $claudeText` (not `Write-Host`) — preserves pipe semantics for downstream callers
- `$claudeObj.modelUsage.PSObject.Properties[0].Name` — extracts first key from PSCustomObject (primary model)
- Cost stored as full double — `ConvertTo-Json` preserves ~10-digit precision, sufficient for USD values
- Parse-failure catch: shows raw text to user, writes metrics without `claudeUsage`, emits `Write-Warning`
- Claude-not-found path: writes metrics without `claudeUsage` before exit 8
- Banner `"--- enviando para claude CLI ---"` stays (UX: user sees banner, waits, sees result)

- [ ] **Step 3: Run integration tests**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/c.Integration.Tests.ps1'
$cfg.Filter.FullName = '*-Send*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 4 -Send tests PASS (2 existing + 2 new).

- [ ] **Step 4: Run full integration suite to check for regressions**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/c.Integration.Tests.ps1'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 15 integration tests PASS (13 existing + 2 new).

- [ ] **Step 5: Commit**

```powershell
git add c.ps1
git commit -m "feat(send): capture Claude CLI JSON output for token usage and cost metrics"
```

---

### Task 5: Write failing summary unit tests — Claude usage fields

**Files:**
- Modify: `Tests/cprompt.Tests.ps1` (add new Describe block after the cold-start detection tests)

- [ ] **Step 1: Add Describe block for Claude usage summary fields**

Add after the closing `}` of `Describe 'Get-MetricsSummary cold-start detection'`:

```powershell
Describe 'Get-MetricsSummary Claude usage aggregation' {
    It 'computes Claude send count, cost, and average tokens' {
        $entries = @(
            [pscustomobject]@{
                claudeUsage = @{
                    inputTokens = 100; outputTokens = 50
                    costUsd = 0.10; durationMs = 2000
                }
            },
            [pscustomobject]@{
                claudeUsage = @{
                    inputTokens = 200; outputTokens = 80
                    costUsd = 0.20; durationMs = 3000
                }
            },
            [pscustomobject]@{ totalMs = 500 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ClaudeSendCount       | Should -Be 2
        $s.ClaudeCostTotal       | Should -Be 0.30
        $s.ClaudeCostAvg         | Should -Be 0.15
        $s.ClaudeAvgInputTokens  | Should -Be 150
        $s.ClaudeAvgOutputTokens | Should -Be 65
    }

    It 'returns zero Claude fields when no entries have claudeUsage' {
        $entries = @(
            [pscustomobject]@{ totalMs = 100 },
            [pscustomobject]@{ totalMs = 200 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ClaudeSendCount       | Should -Be 0
        $s.ClaudeCostTotal       | Should -Be 0
        $s.ClaudeCostAvg         | Should -Be 0
        $s.ClaudeAvgInputTokens  | Should -Be 0
        $s.ClaudeAvgOutputTokens | Should -Be 0
    }

    It 'tolerates mix of entries with and without claudeUsage' {
        $entries = @(
            [pscustomobject]@{
                claudeUsage = @{
                    inputTokens = 80; outputTokens = 40
                    costUsd = 0.05; durationMs = 1000
                }
            },
            [pscustomobject]@{ totalMs = 300 },
            [pscustomobject]@{ totalMs = 400 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ClaudeSendCount       | Should -Be 1
        $s.ClaudeCostTotal       | Should -Be 0.05
        $s.ClaudeCostAvg         | Should -Be 0.05
        $s.ClaudeAvgInputTokens  | Should -Be 80
        $s.ClaudeAvgOutputTokens | Should -Be 40
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
$cfg.Filter.FullName = '*Claude usage*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 3 tests FAIL (properties don't exist on summary).

- [ ] **Step 3: Commit failing tests**

```powershell
git add Tests/cprompt.Tests.ps1
git commit -m "test(summary): add failing tests for Claude usage aggregation fields"
```

---

### Task 6: Implement Get-MetricsSummary — Claude usage fields

**Files:**
- Modify: `cprompt.psm1` (Get-MetricsSummary function)

- [ ] **Step 1: Add Claude usage fields to summary initializer**

In the `$summary = [ordered]@{` block, add after `ColdStartRate = 0.0`:

```powershell
        ClaudeSendCount        = 0
        ClaudeCostTotal        = 0.0
        ClaudeCostAvg          = 0.0
        ClaudeAvgInputTokens   = 0
        ClaudeAvgOutputTokens  = 0
```

- [ ] **Step 2: Add Claude usage aggregation logic**

Insert before the `return [pscustomobject]$summary` line, after the cold-start block:

```powershell
    $claudeEntries = @($Entries | Where-Object { & $hasField $_ 'claudeUsage' })
    if ($claudeEntries.Count -gt 0) {
        $summary.ClaudeSendCount = $claudeEntries.Count
        $costSum   = 0.0
        $inputSum  = 0
        $outputSum = 0
        foreach ($ce in $claudeEntries) {
            $cu = $ce.claudeUsage
            if (& $hasField $cu 'costUsd')      { $costSum   += [double]$cu.costUsd }
            if (& $hasField $cu 'inputTokens')   { $inputSum  += [int]$cu.inputTokens }
            if (& $hasField $cu 'outputTokens')  { $outputSum += [int]$cu.outputTokens }
        }
        $summary.ClaudeCostTotal       = [math]::Round($costSum, 6)
        $summary.ClaudeCostAvg         = [math]::Round($costSum / $claudeEntries.Count, 6)
        $summary.ClaudeAvgInputTokens  = [int][math]::Round($inputSum / $claudeEntries.Count)
        $summary.ClaudeAvgOutputTokens = [int][math]::Round($outputSum / $claudeEntries.Count)
    }
```

- [ ] **Step 3: Run Claude usage summary tests**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*Claude usage*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 3 tests PASS.

- [ ] **Step 4: Run all summary tests to verify no regressions**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*Get-MetricsSummary*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expected: All 17 summary tests PASS (14 existing + 3 new).

- [ ] **Step 5: Commit**

```powershell
git add cprompt.psm1
git commit -m "feat(summary): add ClaudeSendCount, cost, and token averages to Get-MetricsSummary"
```

---

### Task 7: cstats display — Claude usage lines

**Files:**
- Modify: `cstats.ps1` (after the cold-start block, before the mode counts section)

- [ ] **Step 1: Add Claude usage display block**

Insert after the cold-start `if` block and before `Write-Host ''`:

```powershell
if ($summary.ClaudeSendCount -gt 0) {
    Write-Host ("Claude sends     : {0}" -f $summary.ClaudeSendCount)
    Write-Host ("Claude cost total: `${0:N2}" -f $summary.ClaudeCostTotal)
    Write-Host ("Claude cost avg  : `${0:N2}" -f $summary.ClaudeCostAvg)
    Write-Host ("Claude tokens avg: {0} out / {1} in" -f $summary.ClaudeAvgOutputTokens, $summary.ClaudeAvgInputTokens)
}
```

Note: The backtick before `$` in the format string escapes the dollar sign so it displays as a literal `$` currency symbol, not a PowerShell variable.

- [ ] **Step 2: Smoke test cstats**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
powershell.exe -NoProfile -File cstats.ps1 -Last 10
```

Expected: Output includes all existing lines. No errors. Claude lines appear only if metrics file has entries with `claudeUsage` (unlikely in test data, but no crash).

- [ ] **Step 3: Commit**

```powershell
git add cstats.ps1
git commit -m "feat(cstats): display Claude send count, cost, and token averages"
```

---

### Task 8: Full test suite + pre-push audit + push + PR

- [ ] **Step 1: Run full Pester test suite**

Run:
```powershell
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.PS1'
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests -Output Detailed
```

Expected: All tests PASS (236 existing + 5 new = 241, 0 failures).

- [ ] **Step 2: Review diff against main**

Run:
```powershell
git diff main...HEAD --stat
git diff main...HEAD
```

Verify:
- `Tests/integration/claude-impl.ps1`: JSON output + bad-JSON mode
- `c.ps1`: metrics write defer for Send, JSON capture block, `claudeUsage` build
- `Tests/c.Integration.Tests.ps1`: 2 new integration tests
- `Tests/cprompt.Tests.ps1`: 3 new summary tests
- `cprompt.psm1`: 5 new summary fields + aggregation logic
- `cstats.ps1`: Claude usage display lines
- No unrelated changes

- [ ] **Step 3: Push and create PR**

```powershell
git push -u origin feat/metrics-v2-claude-usage
```

```powershell
gh pr create --title "feat: capture Claude CLI token usage and cost on -Send" --body @'
## Summary
- Change `claude -p` to `claude -p --output-format json` in c.ps1
- Parse JSON response: `.result` for display, `.usage`/`.total_cost_usd`/`.modelUsage` for metrics
- Graceful fallback when JSON parse fails (show raw text, skip usage capture)
- Defer `Add-MetricEntry` for `-Send` path so `claudeUsage` can be appended
- New `claudeUsage` object in metrics entry with tokens, cost, duration, model
- `Get-MetricsSummary`: ClaudeSendCount, ClaudeCostTotal/Avg, ClaudeAvgInput/OutputTokens
- cstats display: send count, cost total/avg, token averages

## Trade-offs
- `--output-format json` buffers entire response (no streaming). Accepted for `-Send` pipeline path.
- stderr NOT suppressed — Claude CLI errors still reach user.
- Cost stored as full double, rounded at display only.

## Test plan
- [x] `Invoke-Pester ./Tests` — all 241 tests pass (236 existing + 5 new)
- [ ] `c -Send -NoRefine "test"` with real Claude CLI — verify JSON parsed, claudeUsage in metrics
- [ ] `cstats` after real Send — verify Claude lines appear
- [ ] Old metrics.jsonl entries without `claudeUsage` don't break summary

🤖 Generated with [Claude Code](https://claude.com/claude-code)
'@
```
