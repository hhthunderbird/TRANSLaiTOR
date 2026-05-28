# Metrics v2 — Cold-Start Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect and surface ollama cold-start events (model first-load) in metrics and cstats.

**Architecture:** Extend `ConvertFrom-OllamaVerboseStats` with two new regexes (`load duration`, `total duration`). Raw `loadDurationMs`/`totalDurationMs` flow into existing `compilerEval`/`refinerEval` objects in metrics.jsonl. Cold-start detection is derived at read time in `Get-MetricsSummary` (threshold: `loadDurationMs > 500`). No new top-level keys; no denormalized flags.

**Tech Stack:** PowerShell 5.1, Pester 5.7.1

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `cprompt.psm1:24-68` | Modify | Add `loadDurationMs`/`totalDurationMs` regexes to `ConvertFrom-OllamaVerboseStats` |
| `cprompt.psm1:307-399` | Modify | Add `ColdStartCount`/`ColdStartRate` to `Get-MetricsSummary` |
| `Tests/cprompt.Tests.ps1:796-851` | Modify | Parser unit tests for new duration fields |
| `Tests/cprompt.Tests.ps1:947-989` | Modify | Summary unit tests for cold-start derivation |
| `Tests/integration/fixtures/compiler-valid-xml.json` | Modify | Add warm `load duration` + `total duration` to verbose block |
| `Tests/integration/fixtures/combo-passthrough-valid.json` | Modify | Add cold `load duration` + `total duration` to verbose blocks |
| `Tests/c.Integration.Tests.ps1:204-267` | Modify | Assert `loadDurationMs`/`totalDurationMs` in metrics entries |
| `cstats.ps1:34-44` | Modify | Add cold-start display line |

---

### Task 1: Create feature branch

- [ ] **Step 1: Create and switch to feature branch**

```powershell
git checkout -b feat/metrics-v2-cold-start
```

- [ ] **Step 2: Verify branch**

Run: `git branch --show-current`
Expected: `feat/metrics-v2-cold-start`

---

### Task 2: Parser unit tests — `loadDurationMs` / `totalDurationMs`

**Files:**
- Modify: `Tests/cprompt.Tests.ps1:796-851`

- [ ] **Step 1: Write failing test — cold-start sample with seconds-scale load duration**

Add this test inside the existing `Describe 'ConvertFrom-OllamaVerboseStats'` block, after the last `It` (after line 850):

```powershell
    It 'parses load duration and total duration (cold start, seconds)' {
        $stderr = @"
total duration:       4.5019843s
load duration:        2.8218176s
prompt eval count:    28 token(s)
prompt eval duration: 40.8138ms
eval count:           144 token(s)
eval duration:        4.0391184s
eval rate:            81.85 tokens/s
"@
        $stats = ConvertFrom-OllamaVerboseStats -Text $stderr
        $stats.loadDurationMs  | Should -Be 2822   # 2.8218176s -> 2822 ms
        $stats.totalDurationMs | Should -Be 4502   # 4.5019843s -> 4502 ms
        # Existing fields still parsed.
        $stats.evalRate        | Should -Be 81.85
    }
```

- [ ] **Step 2: Write failing test — warm sample with millisecond-scale load duration**

Add immediately after the cold-start test:

```powershell
    It 'parses load duration and total duration (warm, milliseconds)' {
        $stderr = @"
total duration:       1.5019843s
load duration:        23.1902ms
eval count:           99 token(s)
eval duration:        1.3s
eval rate:            75.91 tokens/s
"@
        $stats = ConvertFrom-OllamaVerboseStats -Text $stderr
        $stats.loadDurationMs  | Should -Be 23     # 23.1902ms -> 23 ms
        $stats.totalDurationMs | Should -Be 1502   # 1.5019843s -> 1502 ms
    }
```

- [ ] **Step 3: Write failing test — partial stderr without load/total still works**

Add after the warm test:

```powershell
    It 'omits loadDurationMs and totalDurationMs when not present in stderr' {
        $stderr = "eval count: 18 tokens`neval rate: 56.3 tokens/s`n"
        $stats = ConvertFrom-OllamaVerboseStats -Text $stderr
        $stats.ContainsKey('loadDurationMs')  | Should -BeFalse
        $stats.ContainsKey('totalDurationMs') | Should -BeFalse
        $stats.evalCount                      | Should -Be 18
    }
```

- [ ] **Step 4: Run tests to verify they fail**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/cprompt.Tests.ps1 -Filter @{ FullName = '*ConvertFrom-OllamaVerboseStats*' } -Output Detailed
```
Expected: 3 new tests FAIL (property not found / key doesn't exist). Existing 6 tests PASS.

- [ ] **Step 5: Commit failing tests**

```powershell
git add Tests/cprompt.Tests.ps1
git commit -m "test(parser): add failing tests for loadDurationMs and totalDurationMs"
```

---

### Task 3: Implement parser — `loadDurationMs` / `totalDurationMs` regexes

**Files:**
- Modify: `cprompt.psm1:62-67` (before the `if ($stats.Count -eq 0)` guard)

- [ ] **Step 1: Add two new regex matches**

Insert these lines in `ConvertFrom-OllamaVerboseStats`, after the `eval rate` regex block (after line 64) and before the `if ($stats.Count -eq 0)` guard (line 66):

```powershell
    $m = [regex]::Match($Text, 'load\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.loadDurationMs = $ms }
    }

    $m = [regex]::Match($Text, 'total\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.totalDurationMs = $ms }
    }
```

No negative lookbehinds needed — `load duration` and `total duration` share no prefix with `eval duration` / `prompt eval duration`.

- [ ] **Step 2: Run parser tests to verify they pass**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/cprompt.Tests.ps1 -Filter @{ FullName = '*ConvertFrom-OllamaVerboseStats*' } -Output Detailed
```
Expected: All 9 tests PASS (6 existing + 3 new).

- [ ] **Step 3: Commit**

```powershell
git add cprompt.psm1
git commit -m "feat(parser): add loadDurationMs and totalDurationMs to ConvertFrom-OllamaVerboseStats"
```

---

### Task 4: Update integration fixtures — add load/total duration to verbose blocks

**Files:**
- Modify: `Tests/integration/fixtures/compiler-valid-xml.json`
- Modify: `Tests/integration/fixtures/combo-passthrough-valid.json`

- [ ] **Step 1: Update `compiler-valid-xml.json` — warm load (23ms)**

Current `prompt-opt.verbose` value ends with `eval rate: 20.0 tokens/s\n`. Append `total duration` and `load duration` lines to the verbose string:

```json
{
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>",
  "prompt-opt.verbose": "prompt eval count: 50 token(s)\nprompt eval duration: 100ms\neval count: 120 token(s)\neval duration: 6.0s\neval rate: 20.0 tokens/s\ntotal duration: 6.5s\nload duration: 23.1902ms\n"
}
```

Values: `load duration: 23.1902ms` (warm, < 500ms threshold), `total duration: 6.5s`.

- [ ] **Step 2: Update `combo-passthrough-valid.json` — cold load on compiler (2.8s), warm on refiner (15ms)**

Append duration lines to both verbose strings:

```json
{
  "prompt-refiner": "<passthrough>sistema ecs unity</passthrough>",
  "prompt-refiner.verbose": "prompt eval count: 30 token(s)\nprompt eval duration: 80ms\neval count: 18 token(s)\neval duration: 320ms\neval rate: 56.3 tokens/s\ntotal duration: 1.2s\nload duration: 15.0ms\n",
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>",
  "prompt-opt.verbose": "prompt eval count: 50 token(s)\nprompt eval duration: 100ms\neval count: 120 token(s)\neval duration: 6.0s\neval rate: 20.0 tokens/s\ntotal duration: 9.3s\nload duration: 2.8218176s\n"
}
```

Values: refiner `load duration: 15.0ms` (warm), compiler `load duration: 2.8218176s` (cold, > 500ms).

- [ ] **Step 3: Run existing integration tests to verify no regressions**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Filter @{ FullName = '*eval stats*' } -Output Detailed
```
Expected: All 3 existing tests PASS (they assert `evalRate`/`evalCount` which are unchanged).

- [ ] **Step 4: Commit**

```powershell
git add Tests/integration/fixtures/compiler-valid-xml.json Tests/integration/fixtures/combo-passthrough-valid.json
git commit -m "test(fixtures): add load duration and total duration to ollama verbose blocks"
```

---

### Task 5: Integration test assertions — `loadDurationMs` / `totalDurationMs` in metrics entries

**Files:**
- Modify: `Tests/c.Integration.Tests.ps1:204-267`

- [ ] **Step 1: Extend `-NoRefine` test (line 217-222) with duration assertions**

Add these assertions after line 220 (`evalDurationMs` assertion), before the `refinerEval` null check:

```powershell
        [int]$entry.compilerEval.loadDurationMs  | Should -Be 23     # warm: 23.1902ms
        [int]$entry.compilerEval.totalDurationMs  | Should -Be 6500   # 6.5s
```

- [ ] **Step 2: Extend passthrough test (line 237-241) with duration assertions**

Add these assertions after line 240 (`compilerEval.evalRate` assertion):

```powershell
        [int]$entry.refinerEval.loadDurationMs   | Should -Be 15     # warm: 15.0ms
        [int]$entry.refinerEval.totalDurationMs   | Should -Be 1200   # 1.2s
        [int]$entry.compilerEval.loadDurationMs  | Should -Be 2822   # cold: 2.8218176s
        [int]$entry.compilerEval.totalDurationMs  | Should -Be 9300   # 9.3s
```

- [ ] **Step 3: Run integration tests**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Filter @{ FullName = '*eval stats*' } -Output Detailed
```
Expected: All 3 tests PASS (parser now captures load/total from fixtures).

- [ ] **Step 4: Commit**

```powershell
git add Tests/c.Integration.Tests.ps1
git commit -m "test(integration): assert loadDurationMs and totalDurationMs in metrics entries"
```

---

### Task 6: Summary unit tests — `ColdStartCount` / `ColdStartRate`

**Files:**
- Modify: `Tests/cprompt.Tests.ps1:947-989`

- [ ] **Step 1: Write failing test — cold-start count from mixed entries**

Add a new `Describe` block after the closing `}` of `Describe 'Get-MetricsSummary with compilerEval entries'` (after line 989):

```powershell
Describe 'Get-MetricsSummary cold-start detection' {
    It 'counts entries with loadDurationMs > 500 as cold starts' {
        $entries = @(
            [pscustomobject]@{ compilerEval = @{ evalRate = 10.0; loadDurationMs = 2822 } },
            [pscustomobject]@{ compilerEval = @{ evalRate = 20.0; loadDurationMs = 23 } },
            [pscustomobject]@{ compilerEval = @{ evalRate = 15.0; loadDurationMs = 800 } },
            [pscustomobject]@{ totalMs = 100 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ColdStartCount | Should -Be 2       # 2822 > 500, 800 > 500
        $s.ColdStartRate  | Should -Be 0.5     # 2/4
    }

    It 'detects cold start from refinerEval.loadDurationMs too' {
        $entries = @(
            [pscustomobject]@{
                refinerEval  = @{ evalRate = 56.3; loadDurationMs = 1500 }
                compilerEval = @{ evalRate = 20.0; loadDurationMs = 23 }
            },
            [pscustomobject]@{
                compilerEval = @{ evalRate = 10.0; loadDurationMs = 10 }
            }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ColdStartCount | Should -Be 1       # refiner 1500 > 500 triggers
        $s.ColdStartRate  | Should -Be 0.5     # 1/2
    }

    It 'returns zero cold starts when no entries have loadDurationMs' {
        $entries = @(
            [pscustomobject]@{ compilerEval = @{ evalRate = 10.0 } },
            [pscustomobject]@{ totalMs = 200 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ColdStartCount | Should -Be 0
        $s.ColdStartRate  | Should -Be 0.0
    }

    It 'treats exactly 500ms as warm (strictly greater threshold)' {
        $entries = @(
            [pscustomobject]@{ compilerEval = @{ evalRate = 10.0; loadDurationMs = 500 } }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ColdStartCount | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/cprompt.Tests.ps1 -Filter @{ FullName = '*cold-start*' } -Output Detailed
```
Expected: All 4 tests FAIL (property `ColdStartCount` does not exist).

- [ ] **Step 3: Commit failing tests**

```powershell
git add Tests/cprompt.Tests.ps1
git commit -m "test(summary): add failing tests for ColdStartCount and ColdStartRate"
```

---

### Task 7: Implement summary — cold-start derivation in `Get-MetricsSummary`

**Files:**
- Modify: `cprompt.psm1:307-399`

- [ ] **Step 1: Add `ColdStartCount` and `ColdStartRate` to summary initializer**

In the `$summary = [ordered]@{` block (around line 316), add after `CompilerEvalCountMedian = 0`:

```powershell
        ColdStartCount         = 0
        ColdStartRate          = 0.0
```

- [ ] **Step 2: Add cold-start derivation logic**

Insert before the `return [pscustomobject]$summary` line (line 398), after the `CompilerEvalCountMedian` block:

```powershell
    # Cold-start detection: entry is cold if either refinerEval or compilerEval
    # has loadDurationMs > 500. Threshold: strictly greater than 500.
    $coldCount = 0
    foreach ($e in $Entries) {
        $isCold = $false
        foreach ($evalKey in @('compilerEval', 'refinerEval')) {
            if (& $hasField $e $evalKey) {
                $evalObj = $e.$evalKey
                if ((& $hasField $evalObj 'loadDurationMs') -and [int]$evalObj.loadDurationMs -gt 500) {
                    $isCold = $true
                    break
                }
            }
        }
        if ($isCold) { $coldCount++ }
    }
    $summary.ColdStartCount = $coldCount
    if ($Entries.Count -gt 0) {
        $summary.ColdStartRate = [math]::Round($coldCount / $Entries.Count, 4)
    }
```

- [ ] **Step 3: Run cold-start summary tests**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/cprompt.Tests.ps1 -Filter @{ FullName = '*cold-start*' } -Output Detailed
```
Expected: All 4 tests PASS.

- [ ] **Step 4: Run all summary tests to verify no regressions**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests/cprompt.Tests.ps1 -Filter @{ FullName = '*Get-MetricsSummary*' } -Output Detailed
```
Expected: All existing + new summary tests PASS.

- [ ] **Step 5: Commit**

```powershell
git add cprompt.psm1
git commit -m "feat(summary): derive ColdStartCount and ColdStartRate from loadDurationMs > 500 threshold"
```

---

### Task 8: cstats display — cold-start line

**Files:**
- Modify: `cstats.ps1` (after the compiler eval block, around line 40)

- [ ] **Step 1: Add cold-start display line**

Insert after the compiler eval stats block (`if ($summary.CompilerEvalCountMedian -gt 0) { ... }`) and before the empty line + mode counts section:

```powershell
if ($summary.ColdStartCount -gt 0) {
    Write-Host ("Cold starts      : {0}/{1} ({2:P1})" -f $summary.ColdStartCount, $summary.Count, $summary.ColdStartRate)
}
```

- [ ] **Step 2: Smoke test cstats manually**

Run:
```powershell
pwsh -File cstats.ps1 -Last 10
```
Expected: Output includes all existing lines. If metrics file has entries with `loadDurationMs > 500`, a `Cold starts` line appears. No errors.

- [ ] **Step 3: Commit**

```powershell
git add cstats.ps1
git commit -m "feat(cstats): display cold-start count and rate"
```

---

### Task 9: Full test suite and pre-push audit

- [ ] **Step 1: Run full Pester test suite**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests -Output Detailed
```
Expected: All tests PASS (229 existing + 7 new = 236, 0 failures).

- [ ] **Step 2: Review diff against main**

Run:
```powershell
git diff main...HEAD --stat
git diff main...HEAD
```

Verify:
- `cprompt.psm1`: only parser regexes + summary cold-start block added
- `cstats.ps1`: only cold-start display line added
- `Tests/cprompt.Tests.ps1`: parser + summary tests added
- `Tests/c.Integration.Tests.ps1`: duration assertions added
- Fixtures: only verbose strings extended (existing values unchanged)
- No unrelated changes

- [ ] **Step 3: Push and create PR**

```powershell
git push -u origin feat/metrics-v2-cold-start
gh pr create --title "feat: cold-start detection in metrics and cstats" --body "$(cat <<'EOF'
## Summary
- Extend `ConvertFrom-OllamaVerboseStats` with `loadDurationMs`/`totalDurationMs` regexes
- Derive cold-start at read time in `Get-MetricsSummary` (loadDurationMs > 500 threshold)
- Display `Cold starts: N/M (X.X%)` in cstats when cold starts detected
- Unit tests for parser (cold/warm samples) and summary (mixed entries, threshold boundary)
- Integration test assertions for duration fields in metrics entries

## Test plan
- [ ] `Invoke-Pester ./Tests` — all 236 tests pass
- [ ] `cstats -Last 10` shows cold-start line (if applicable data exists)
- [ ] Verify old metrics.jsonl entries without `loadDurationMs` don't break summary

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
