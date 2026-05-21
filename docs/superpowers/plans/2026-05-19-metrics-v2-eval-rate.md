# Metrics v2 — Ollama eval rate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture per-run Ollama `--verbose` generation stats (eval rate, token counts, durations) for refiner and compiler calls, attach them as opt-in keys to existing metrics JSONL entries, and surface a compact compiler-throughput summary in `cstats`.

**Architecture:** Add a `-CaptureStats` switch to `Invoke-OllamaModel` that swaps the PS-pipeline invocation for `System.Diagnostics.Process` so stderr is captured as raw bytes (PS 5.1 mangles native stderr via `NativeCommandError` when redirected through `2>$file`). A new pure `ConvertFrom-OllamaVerboseStats` parses the (ANSI-stripped) stderr text into a hashtable. `c.ps1` keeps the existing wall-clock fields and adds two opt-in keys (`refinerEval`, `compilerEval`) when stats are available. `Get-MetricsSummary` + `cstats.ps1` gain percentile/median outputs for compiler eval rate and token count.

**Tech Stack:** PowerShell 5.1, Pester 5 (`-RequiredVersion 5.7.1`), `cprompt.psm1` module, integration test harness with PATH-shim fixtures under `Tests/integration/`.

**Spec:** `docs/superpowers/specs/2026-05-17-metrics-v2-eval-rate-design.md`

---

## File Structure

**Modified:**
- `cprompt.psm1` — add `ConvertFrom-OllamaVerboseStats`; extend `Invoke-OllamaModel` with `-CaptureStats`; extend `Get-MetricsSummary`; extend `Export-ModuleMember`.
- `c.ps1` — switch refiner + compiler `Invoke-OllamaModel` calls to `-CaptureStats`; capture `.Text` / `.Stats`; add opt-in keys to metrics entry.
- `cstats.ps1` — emit three new lines when summary contains the new fields.
- `Tests/integration/ollama-impl.ps1` — also write `<model>.verbose` from fixture to stderr when present.
- `Tests/integration/fixtures/combo-passthrough-valid.json` — add `prompt-refiner.verbose` + `prompt-opt.verbose`.
- `Tests/integration/fixtures/compiler-valid-xml.json` — add `prompt-opt.verbose`.

**Added:**
- `Tests/integration/fixtures/eval-cache-hit.json` — minimal fixture for the cache-hit-no-stats test.
- New `Describe` blocks in `Tests/c.Integration.Tests.ps1`.
- New `Describe` blocks in `Tests/cprompt.Tests.ps1`.

Boundaries: parser is a pure function (regex + hashtable). Process invocation is one branch inside `Invoke-OllamaModel`. Metric wiring is two assignments + two `if ($x) { $entry.k = $x }` lines. Summary computation reuses the existing entry-iteration shape.

---

## Task 1: Add `ConvertFrom-OllamaVerboseStats` (pure parser)

**Files:**
- Modify: `cprompt.psm1` (insert function after `Remove-AnsiEscapes` at line 22; extend `Export-ModuleMember` at line 425-447)
- Test: `Tests/cprompt.Tests.ps1` (append new `Describe` blocks at EOF)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/cprompt.Tests.ps1` (EOF):

```powershell
Describe 'ConvertFrom-OllamaVerboseStats' {
    It 'parses full canonical stderr block with mixed units and token(s) suffix' {
        $stderr = @"
prompt eval count:    28 token(s)
prompt eval duration: 40.8138ms
eval count:           144 token(s)
eval duration:        4.0391184s
eval rate:            81.85 tokens/s
"@
        $stats = ConvertFrom-OllamaVerboseStats -Text $stderr
        $stats                          | Should -Not -BeNullOrEmpty
        $stats.promptEvalCount          | Should -Be 28
        $stats.promptEvalDurationMs     | Should -Be 41   # 40.8138 -> round to int
        $stats.evalCount                | Should -Be 144
        $stats.evalDurationMs           | Should -Be 4039 # 4.0391184s -> 4039 ms
        $stats.evalRate                 | Should -Be 81.85
    }

    It 'returns only fields that matched on partial stderr' {
        $stderr = "eval count: 18 tokens`neval rate: 56.3 tokens/s`n"
        $stats = ConvertFrom-OllamaVerboseStats -Text $stderr
        $stats.ContainsKey('evalCount')              | Should -BeTrue
        $stats.ContainsKey('evalRate')               | Should -BeTrue
        $stats.ContainsKey('promptEvalCount')        | Should -BeFalse
        $stats.ContainsKey('promptEvalDurationMs')   | Should -BeFalse
        $stats.ContainsKey('evalDurationMs')         | Should -BeFalse
        $stats.evalCount                             | Should -Be 18
        $stats.evalRate                              | Should -Be 56.3
    }

    It 'returns $null on empty or unrelated stderr' {
        ConvertFrom-OllamaVerboseStats -Text ''               | Should -BeNullOrEmpty
        ConvertFrom-OllamaVerboseStats -Text 'random noise'   | Should -BeNullOrEmpty
        ConvertFrom-OllamaVerboseStats -Text $null            | Should -BeNullOrEmpty
    }

    It 'parses after ANSI escapes are stripped (caller responsibility documented)' {
        $stderr = "`e[?2026h`e[2K`r" + "eval rate: 18.2 tokens/s`n"
        $clean = Remove-AnsiEscapes -Text $stderr
        $stats = ConvertFrom-OllamaVerboseStats -Text $clean
        $stats.evalRate | Should -Be 18.2
    }

    It 'parses durations: 12.345s -> 12345, 200ms -> 200' {
        $a = ConvertFrom-OllamaVerboseStats -Text "eval duration: 12.345s`n"
        $b = ConvertFrom-OllamaVerboseStats -Text "eval duration: 200ms`n"
        $a.evalDurationMs | Should -Be 12345
        $b.evalDurationMs | Should -Be 200
    }

    It 'is case-insensitive and tolerant of whitespace drift' {
        $stderr = "Eval Rate:   42.0 tokens/s`n"
        $stats = ConvertFrom-OllamaVerboseStats -Text $stderr
        $stats.evalRate | Should -Be 42.0
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests/cprompt.Tests.ps1 -Output Detailed
```
Expected: 6 new tests fail with `The term 'ConvertFrom-OllamaVerboseStats' is not recognized` (or equivalent).

- [ ] **Step 3: Implement `ConvertFrom-OllamaVerboseStats`**

Insert into `cprompt.psm1` immediately after the `Remove-AnsiEscapes` function (i.e. after the closing `}` on line 22):

```powershell
function ConvertFrom-OllamaVerboseStats {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $stats = @{}

    # Duration helper: float + unit -> int ms.
    $toMs = {
        param($value, $unit)
        $n = [double]$value
        switch ($unit.ToLowerInvariant()) {
            'ms' { return [int][math]::Round($n) }
            's'  { return [int][math]::Round($n * 1000.0) }
            default { return $null }
        }
    }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    $m = [regex]::Match($Text, 'prompt\s+eval\s+count:\s*(\d+)\s*token', $opts)
    if ($m.Success) { $stats.promptEvalCount = [int]$m.Groups[1].Value }

    $m = [regex]::Match($Text, 'prompt\s+eval\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.promptEvalDurationMs = $ms }
    }

    # The 'eval count' regex must NOT match 'prompt eval count' — anchor on word boundary.
    $m = [regex]::Match($Text, '(?<!prompt\s)\beval\s+count:\s*(\d+)\s*token', $opts)
    if ($m.Success) { $stats.evalCount = [int]$m.Groups[1].Value }

    $m = [regex]::Match($Text, '(?<!prompt\s)\beval\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.evalDurationMs = $ms }
    }

    $m = [regex]::Match($Text, 'eval\s+rate:\s*([\d.]+)\s*tokens?/s', $opts)
    if ($m.Success) { $stats.evalRate = [double]$m.Groups[1].Value }

    if ($stats.Count -eq 0) { return $null }
    return $stats
}
```

- [ ] **Step 4: Export the new function**

Edit `Export-ModuleMember` (lines ~425-447 in `cprompt.psm1`): add `ConvertFrom-OllamaVerboseStats,` to the comma-separated list. Place it on its own line after `Remove-AnsiEscapes,` for grouping:

```powershell
Export-ModuleMember -Function `
    Remove-Bom, `
    Remove-AnsiEscapes, `
    ConvertFrom-OllamaVerboseStats, `
    Get-PromptXml, `
    Test-PromptXml, `
    Resolve-CompilerFallback, `
    Resolve-Tool, `
    Test-CommandPresent, `
    Invoke-OllamaModel, `
    Test-InputAcceptable, `
    Test-InputIsZeroSignal, `
    Get-CacheKey, `
    Get-CachedXml, `
    Set-CachedXml, `
    Add-HistoryEntry, `
    Get-LastHistoryEntry, `
    Add-MetricEntry, `
    Read-MetricsFile, `
    Get-MetricsSummary, `
    Get-RefinerOutput, `
    Test-RefinerOutput, `
    Merge-RefinementAnswers, `
    Get-RefinerRegressions
```

- [ ] **Step 5: Run tests and verify they pass**

Run:
```powershell
Invoke-Pester ./Tests/cprompt.Tests.ps1 -Output Detailed
```
Expected: all `ConvertFrom-OllamaVerboseStats` tests PASS. Full file still green.

- [ ] **Step 6: Commit**

```powershell
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(cprompt): add ConvertFrom-OllamaVerboseStats parser"
```

---

## Task 2: Add `-CaptureStats` to `Invoke-OllamaModel`

**Files:**
- Modify: `cprompt.psm1:88-98` (replace `Invoke-OllamaModel`)
- Test: `Tests/cprompt.Tests.ps1` (append new `Describe` block)

- [ ] **Step 1: Write failing tests**

Append to `Tests/cprompt.Tests.ps1` (EOF):

```powershell
Describe 'Invoke-OllamaModel -CaptureStats' -Tag 'integration' {
    BeforeAll {
        # Stand up a per-test PATH-shim ollama so we exercise the Process branch
        # without needing real ollama. Reuse the integration test stub.
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:binDir = Join-Path $TestDrive 'ollama-bin'
        New-Item -ItemType Directory -Path $script:binDir -Force | Out-Null
        Copy-Item (Join-Path $script:repoRoot 'Tests/integration/ollama.cmd') (Join-Path $script:binDir 'ollama.cmd') -Force
        Copy-Item (Join-Path $script:repoRoot 'Tests/integration/ollama-impl.ps1') (Join-Path $script:binDir 'ollama-impl.ps1') -Force

        $script:fixturePath = Join-Path $TestDrive 'fixture.json'
        @{
            'test-model' = '<task>x</task><context>y</context><constraints>z</constraints>'
            'test-model.verbose' = "prompt eval count: 10 token(s)`nprompt eval duration: 50ms`neval count: 20 token(s)`neval duration: 1.5s`neval rate: 13.3 tokens/s`n"
        } | ConvertTo-Json | Set-Content -LiteralPath $script:fixturePath -Encoding UTF8

        $script:savedPath = $env:Path
        $script:savedFix = $env:CPROMPT_TEST_FIXTURE
        $env:Path = "$script:binDir;$env:Path"
        $env:CPROMPT_TEST_FIXTURE = $script:fixturePath
    }
    AfterAll {
        $env:Path = $script:savedPath
        if ($null -ne $script:savedFix) { $env:CPROMPT_TEST_FIXTURE = $script:savedFix } else { Remove-Item Env:\CPROMPT_TEST_FIXTURE -ErrorAction SilentlyContinue }
    }

    It 'without -CaptureStats: returns string (backward compatible)' {
        $result = Invoke-OllamaModel -Text 'hello' -Model 'test-model'
        $result | Should -BeOfType [string]
        $result | Should -Match '<task>x</task>'
    }

    It 'with -CaptureStats: returns object with .Text and .Stats' {
        $result = Invoke-OllamaModel -Text 'hello' -Model 'test-model' -CaptureStats
        $result.Text         | Should -Match '<task>x</task>'
        $result.Stats        | Should -Not -BeNullOrEmpty
        $result.Stats.evalRate     | Should -Be 13.3
        $result.Stats.evalCount    | Should -Be 20
        $result.Stats.evalDurationMs | Should -Be 1500
    }

    It 'with -CaptureStats and no verbose fixture: returns .Stats = $null' {
        $bareFixture = Join-Path $TestDrive 'bare.json'
        @{ 'bare-model' = '<task>a</task><context>b</context><constraints>c</constraints>' } |
            ConvertTo-Json | Set-Content -LiteralPath $bareFixture -Encoding UTF8

        $saved = $env:CPROMPT_TEST_FIXTURE
        $env:CPROMPT_TEST_FIXTURE = $bareFixture
        try {
            $result = Invoke-OllamaModel -Text 'hello' -Model 'bare-model' -CaptureStats
        } finally {
            $env:CPROMPT_TEST_FIXTURE = $saved
        }
        $result.Text  | Should -Match '<task>a</task>'
        $result.Stats | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:
```powershell
Invoke-Pester ./Tests/cprompt.Tests.ps1 -Output Detailed
```
Expected: new `-CaptureStats` tests fail (parameter not found).

- [ ] **Step 3: Replace `Invoke-OllamaModel` (cprompt.psm1:88-98)**

Replace the entire existing function with:

```powershell
function Invoke-OllamaModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Model,
        [switch]$CaptureStats
    )

    if (-not $CaptureStats) {
        # Legacy path. `2>$null` swallows the terminal progress spinner ollama
        # prints to stderr. `--nowordwrap` keeps tag bodies on one logical line;
        # ANSI escapes are still cleaned downstream by Remove-AnsiEscapes /
        # Get-RefinerOutput.
        return ($Text | & ollama run --nowordwrap $Model 2>$null | Out-String)
    }

    # Stats path. Use System.Diagnostics.Process so stderr is captured raw —
    # PS 5.1 wraps native stderr as NativeCommandError records when redirected
    # via `2>$file`, which pollutes the bytes we need to regex-parse.
    $cmd = Get-Command 'ollama' -ErrorAction Stop
    $source = $cmd.Source

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $isShim = $source -match '\.(cmd|bat)$'
    if ($isShim) {
        # CreateProcess can't exec .cmd directly; route through cmd.exe.
        $psi.FileName  = "$env:SystemRoot\System32\cmd.exe"
        $psi.Arguments = '/c "' + $source + '" run --verbose --nowordwrap ' + $Model
    } else {
        $psi.FileName  = $source
        $psi.Arguments = 'run --verbose --nowordwrap ' + $Model
    }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $p = [System.Diagnostics.Process]::Start($psi)

    # Async stdout/stderr reads avoid deadlock if either stream fills its pipe
    # buffer before WaitForExit. Stdin is written then closed.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $p.StandardInput.Write($Text)
    $p.StandardInput.Close()

    $p.WaitForExit()
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()

    # Propagate ollama exit code to $LASTEXITCODE for callers that check it
    # (c.ps1 does at line ~234).
    $global:LASTEXITCODE = $p.ExitCode

    $statsText = Remove-AnsiEscapes -Text $stderr
    $stats = ConvertFrom-OllamaVerboseStats -Text $statsText

    return [pscustomobject]@{ Text = $stdout; Stats = $stats }
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run:
```powershell
Invoke-Pester ./Tests/cprompt.Tests.ps1 -Output Detailed
```
Expected: all `Invoke-OllamaModel -CaptureStats` tests PASS. Existing cprompt tests still PASS.

- [ ] **Step 5: Commit**

```powershell
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(cprompt): add -CaptureStats to Invoke-OllamaModel"
```

---

## Task 3: Teach integration stub `ollama-impl.ps1` to emit verbose stderr

**Files:**
- Modify: `Tests/integration/ollama-impl.ps1` (insert before final `exit 0`)
- Modify: `Tests/integration/fixtures/compiler-valid-xml.json`
- Modify: `Tests/integration/fixtures/combo-passthrough-valid.json`

- [ ] **Step 1: Update `Tests/integration/ollama-impl.ps1`**

Replace lines 26-34 (the model-lookup + write-stdout tail) with:

```powershell
if (-not $fixture.PSObject.Properties[$model]) {
    [Console]::Error.WriteLine("stub: model '$model' not in fixture $($env:CPROMPT_TEST_FIXTURE)")
    exit 1
}

[Console]::Out.Write([string]$fixture.$model)

# Optional sibling key '<model>.verbose' lets fixtures opt into emitting an
# Ollama-style --verbose block to stderr. Only meaningful when the caller passed
# --verbose; we emit unconditionally because Invoke-OllamaModel -CaptureStats is
# what triggers stderr capture.
$verboseKey = "$model.verbose"
if ($fixture.PSObject.Properties[$verboseKey]) {
    [Console]::Error.Write([string]$fixture.$verboseKey)
}

exit 0
```

- [ ] **Step 2: Update `Tests/integration/fixtures/compiler-valid-xml.json`**

Replace contents with:

```json
{
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>",
  "prompt-opt.verbose": "prompt eval count: 50 token(s)\nprompt eval duration: 100ms\neval count: 120 token(s)\neval duration: 6.0s\neval rate: 20.0 tokens/s\n"
}
```

- [ ] **Step 3: Update `Tests/integration/fixtures/combo-passthrough-valid.json`**

Replace contents with:

```json
{
  "prompt-refiner": "<passthrough>sistema ecs unity</passthrough>",
  "prompt-refiner.verbose": "prompt eval count: 30 token(s)\nprompt eval duration: 80ms\neval count: 18 token(s)\neval duration: 320ms\neval rate: 56.3 tokens/s\n",
  "prompt-opt": "<task>fixture task body</task>\n<context>fixture context body</context>\n<constraints>fixture constraints body</constraints>",
  "prompt-opt.verbose": "prompt eval count: 50 token(s)\nprompt eval duration: 100ms\neval count: 120 token(s)\neval duration: 6.0s\neval rate: 20.0 tokens/s\n"
}
```

- [ ] **Step 4: Sanity-run the existing integration suite (must stay green)**

Run:
```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: all existing tests PASS. The stub's new stderr write should be invisible to assertions that only check `StdOut`, `Invocations`, history, cache.

- [ ] **Step 5: Commit**

```powershell
git add Tests/integration/ollama-impl.ps1 Tests/integration/fixtures/compiler-valid-xml.json Tests/integration/fixtures/combo-passthrough-valid.json
git commit -m "test(integration): emit <model>.verbose to stderr from ollama stub"
```

---

## Task 4: Wire `-CaptureStats` + opt-in metrics keys in `c.ps1`

**Files:**
- Modify: `c.ps1:131-185` (refiner block)
- Modify: `c.ps1:203-252` (compiler block)
- Modify: `c.ps1:264-287` (metrics-entry build)

- [ ] **Step 1: Add `$refinerStats` / `$compilerStats` initialization**

In `c.ps1`, locate the line that initializes `$refinerMs` near the top of the script (search for the first `$refinerMs = 0` or equivalent — currently `$refinerMs` is only assigned inside the refiner block at line 147). Add at the top of the run-state block (near `$runStart = [System.Diagnostics.Stopwatch]::StartNew()` — verify exact location before this task) the two new locals so they exist on every code path:

Search for `$runStart = [System.Diagnostics.Stopwatch]::StartNew()` and immediately after it, insert:

```powershell
$refinerStats  = $null
$compilerStats = $null
```

If `$refinerMs` / `$compilerMs` are not already initialized to `0` before the conditional blocks, also add:

```powershell
$refinerMs  = 0
$compilerMs = 0
```

(Skip whichever already exists; do not duplicate.)

- [ ] **Step 2: Switch refiner invocation to `-CaptureStats` (c.ps1:142)**

Replace this block (inside the `if ($ollamaPresent)` branch, around lines 139-146):

```powershell
        $refinerRaw = ''
        $refinerWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $refinerRaw = Invoke-OllamaModel -Text $userInput -Model $RefinerModel
        } catch {
            $refinerRaw = ''
        }
        $refinerWatch.Stop()
        $refinerMs = [int]$refinerWatch.ElapsedMilliseconds
```

with:

```powershell
        $refinerRaw = ''
        $refinerWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $refinerResult = Invoke-OllamaModel -Text $userInput -Model $RefinerModel -CaptureStats
            $refinerRaw    = [string]$refinerResult.Text
            $refinerStats  = $refinerResult.Stats
        } catch {
            $refinerRaw = ''
        }
        $refinerWatch.Stop()
        $refinerMs = [int]$refinerWatch.ElapsedMilliseconds
```

- [ ] **Step 3: Switch compiler invocation to `-CaptureStats` (c.ps1:223)**

Replace (around lines 220-231):

```powershell
    $ollamaOutput = ''
    $compilerWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ollamaOutput = Invoke-OllamaModel -Text $userInput -Model $Model
    } catch {
        $compilerWatch.Stop()
        $ErrorActionPreference = $prevEAP
        Write-Host "ERRO: falha ao executar ollama: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }
    $compilerWatch.Stop()
    $compilerMs = [int]$compilerWatch.ElapsedMilliseconds
```

with:

```powershell
    $ollamaOutput = ''
    $compilerWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $compilerResult = Invoke-OllamaModel -Text $userInput -Model $Model -CaptureStats
        $ollamaOutput   = [string]$compilerResult.Text
        $compilerStats  = $compilerResult.Stats
    } catch {
        $compilerWatch.Stop()
        $ErrorActionPreference = $prevEAP
        Write-Host "ERRO: falha ao executar ollama: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }
    $compilerWatch.Stop()
    $compilerMs = [int]$compilerWatch.ElapsedMilliseconds
```

- [ ] **Step 4: Add opt-in keys to metrics entry (c.ps1:267-283)**

Replace the `$entry = @{ ... }` block (around lines 267-283):

```powershell
    $entry = @{
        model         = $Model
        refinerModel  = $RefinerModel
        mode          = $metricMode
        inputChars    = $rawInput.Length
        refinedChars  = $userInput.Length
        xmlChars      = $xmlLen
        refinerMs     = $refinerMs
        compilerMs    = $compilerMs
        totalMs       = [int]$runStart.ElapsedMilliseconds
        cacheHit      = [bool]$fromCache
        flags         = @{
            Raw      = [bool]$Raw
            NoRefine = [bool]$NoRefine
            Send     = [bool]$Send
        }
    }
    Add-MetricEntry -Path $metricsPath -Entry $entry
```

with:

```powershell
    $entry = @{
        model         = $Model
        refinerModel  = $RefinerModel
        mode          = $metricMode
        inputChars    = $rawInput.Length
        refinedChars  = $userInput.Length
        xmlChars      = $xmlLen
        refinerMs     = $refinerMs
        compilerMs    = $compilerMs
        totalMs       = [int]$runStart.ElapsedMilliseconds
        cacheHit      = [bool]$fromCache
        flags         = @{
            Raw      = [bool]$Raw
            NoRefine = [bool]$NoRefine
            Send     = [bool]$Send
        }
    }
    # Opt-in eval-stats keys: present only when Invoke-OllamaModel actually
    # captured non-null stats. Absent on cache hits (compiler skipped) and on
    # -NoRefine / refiner-bypassed runs.
    if ($refinerStats)  { $entry.refinerEval  = $refinerStats }
    if ($compilerStats) { $entry.compilerEval = $compilerStats }
    Add-MetricEntry -Path $metricsPath -Entry $entry
```

- [ ] **Step 5: Smoke-test by hand (no real ollama required)**

Run the existing integration suite — it exercises both refiner and compiler paths through the PATH-shim stub now emitting verbose stderr.

```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: existing tests PASS. New keys are present in metrics.jsonl entries but no existing assertion looks at them yet.

- [ ] **Step 6: Commit**

```powershell
git add c.ps1
git commit -m "feat(c): capture refiner/compiler eval stats in metrics entry"
```

---

## Task 5: Integration tests for eval-stats end-to-end

**Files:**
- Modify: `Tests/c.Integration.Tests.ps1` (append new `Describe` blocks at EOF)

- [ ] **Step 1: Write failing tests**

Append to `Tests/c.Integration.Tests.ps1`:

```powershell
Describe 'c.ps1 eval stats captured in metrics entry' {
    It 'compiler eval stats land in metrics entry on -NoRefine run' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-NoRefine','-Raw','sistema ecs unity')

        $r.ExitCode | Should -Be 0
        Test-Path $r.MetricsPath | Should -BeTrue

        # NOTE: wrap in @(...) — PS 5.1's `Get-Content | Where-Object` returns a
        # scalar [string] for single-line files; `$scalar[-1]` then yields a [char]
        # which piped to ConvertFrom-Json blows up with "Invalid JSON primitive: .".
        $lines = @(Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_ -and $_.Trim() })
        $entry = $lines[-1] | ConvertFrom-Json
        $entry.compilerEval                   | Should -Not -BeNullOrEmpty
        [double]$entry.compilerEval.evalRate  | Should -Be 20.0
        [int]$entry.compilerEval.evalCount    | Should -Be 120
        [int]$entry.compilerEval.evalDurationMs | Should -Be 6000
        # No refiner ran on -NoRefine.
        $entry.PSObject.Properties['refinerEval'] | Should -BeNullOrEmpty
    }

    It 'refiner and compiler eval stats both land on passthrough run' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-passthrough-valid.json') `
            -Args @('sistema ecs unity 3d game')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        $lines = @(Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_ -and $_.Trim() })
        $entry = $lines[-1] | ConvertFrom-Json
        $entry.refinerEval                   | Should -Not -BeNullOrEmpty
        [double]$entry.refinerEval.evalRate  | Should -Be 56.3
        $entry.compilerEval                  | Should -Not -BeNullOrEmpty
        [double]$entry.compilerEval.evalRate | Should -Be 20.0
    }

    It 'no compilerEval on cache-hit second run; refinerEval still present' {
        $fixture = Join-Path $script:fixtures 'combo-passthrough-valid.json'

        $run1 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('sistema ecs unity 3d game')
        $run1.ExitCode    | Should -Be 0

        $run2 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('sistema ecs unity 3d game')
        $run2.Invocations | Should -Be @('prompt-refiner')  # compiler skipped (cache)

        $lines = @(Get-Content -LiteralPath $run2.MetricsPath | Where-Object { $_ -and $_.Trim() })
        $entry = $lines[-1] | ConvertFrom-Json
        $entry.mode                           | Should -Be 'cache'
        $entry.cacheHit                       | Should -BeTrue
        $entry.PSObject.Properties['compilerEval'] | Should -BeNullOrEmpty
        $entry.refinerEval                    | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run tests and verify they pass**

Run:
```powershell
Invoke-Pester ./Tests/c.Integration.Tests.ps1 -Output Detailed
```
Expected: 3 new `It` blocks PASS. Existing integration tests still green.

- [ ] **Step 3: Commit**

```powershell
git add Tests/c.Integration.Tests.ps1
git commit -m "test(integration): assert eval stats in metrics entry"
```

---

## Task 6: Extend `Get-MetricsSummary` with compiler eval fields

**Files:**
- Modify: `cprompt.psm1:201-262` (`Get-MetricsSummary`)
- Test: `Tests/cprompt.Tests.ps1` (append new `Describe` block)

- [ ] **Step 1: Write failing tests**

Append to `Tests/cprompt.Tests.ps1`:

```powershell
Describe 'Get-MetricsSummary with compilerEval entries' {
    It 'computes p50, p95 of evalRate and median of evalCount' {
        # Five entries with hand-pickable percentiles. After sort:
        # evalRate sorted: 5, 8, 12, 18, 30 -> p50 (ceil(0.5*5)=3) -> 12; p95 (ceil(0.95*5)=5) -> 30
        # evalCount sorted: 50, 80, 100, 140, 200 -> median (index ceil(0.5*5)-1=2) -> 100
        $entries = @(
            [pscustomobject]@{ compilerEval = @{ evalRate = 12.0; evalCount = 100 } },
            [pscustomobject]@{ compilerEval = @{ evalRate = 5.0;  evalCount = 200 } },
            [pscustomobject]@{ compilerEval = @{ evalRate = 30.0; evalCount = 50  } },
            [pscustomobject]@{ compilerEval = @{ evalRate = 8.0;  evalCount = 140 } },
            [pscustomobject]@{ compilerEval = @{ evalRate = 18.0; evalCount = 80  } }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.CompilerEvalRateP50      | Should -Be 12.0
        $s.CompilerEvalRateP95      | Should -Be 30.0
        $s.CompilerEvalCountMedian  | Should -Be 100
    }

    It 'returns 0 (or absent semantics: zero) when no entries have compilerEval' {
        $entries = @(
            [pscustomobject]@{ totalMs = 100 },
            [pscustomobject]@{ totalMs = 200 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.CompilerEvalRateP50      | Should -Be 0
        $s.CompilerEvalRateP95      | Should -Be 0
        $s.CompilerEvalCountMedian  | Should -Be 0
    }

    It 'tolerates mix of entries with and without compilerEval' {
        $entries = @(
            [pscustomobject]@{ compilerEval = @{ evalRate = 10.0; evalCount = 60 } },
            [pscustomobject]@{ totalMs = 200 },
            [pscustomobject]@{ compilerEval = @{ evalRate = 20.0; evalCount = 80 } }
        )
        $s = Get-MetricsSummary -Entries $entries
        # Sorted evalRate: 10, 20 -> p50 (ceil(0.5*2)=1) -> 10; p95 (ceil(0.95*2)=2) -> 20
        $s.CompilerEvalRateP50      | Should -Be 10.0
        $s.CompilerEvalRateP95      | Should -Be 20.0
        # Sorted evalCount: 60, 80 -> median (index ceil(0.5*2)-1=0) -> 60
        $s.CompilerEvalCountMedian  | Should -Be 60
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:
```powershell
Invoke-Pester ./Tests/cprompt.Tests.ps1 -Output Detailed
```
Expected: 3 new tests fail with `CompilerEvalRateP50` (etc.) not found on summary object.

- [ ] **Step 3: Extend `Get-MetricsSummary`**

In `cprompt.psm1`, modify the `$summary = [ordered]@{ ... }` initializer (lines 213-220) to add three new keys:

```powershell
    $summary = [ordered]@{
        Count                  = $Entries.Count
        CacheHitRate           = 0.0
        LatencyP50             = 0
        LatencyP95             = 0
        AvgCompressionRatio    = 0.0
        ModeCounts             = @{}
        CompilerEvalRateP50    = 0
        CompilerEvalRateP95    = 0
        CompilerEvalCountMedian = 0
    }
```

Then, immediately before the `return [pscustomobject]$summary` (currently line 262), insert:

```powershell
    # Compiler eval stats — present only on entries that captured them.
    $getCompilerEval = {
        param($e)
        $hasIt = & $hasField $e 'compilerEval'
        if (-not $hasIt) { return $null }
        return $e.compilerEval
    }

    $rates = @($Entries |
        ForEach-Object { & $getCompilerEval $_ } |
        Where-Object { $_ -and (& $hasField $_ 'evalRate') } |
        ForEach-Object { [double]$_.evalRate } |
        Sort-Object)
    if ($rates.Count -gt 0) {
        $summary.CompilerEvalRateP50 = $rates[[math]::Max(0, [math]::Ceiling(0.50 * $rates.Count) - 1)]
        $summary.CompilerEvalRateP95 = $rates[[math]::Max(0, [math]::Ceiling(0.95 * $rates.Count) - 1)]
    }

    $counts = @($Entries |
        ForEach-Object { & $getCompilerEval $_ } |
        Where-Object { $_ -and (& $hasField $_ 'evalCount') } |
        ForEach-Object { [int]$_.evalCount } |
        Sort-Object)
    if ($counts.Count -gt 0) {
        $summary.CompilerEvalCountMedian = $counts[[math]::Max(0, [math]::Ceiling(0.50 * $counts.Count) - 1)]
    }
```

- [ ] **Step 4: Run tests and verify they pass**

Run:
```powershell
Invoke-Pester ./Tests/cprompt.Tests.ps1 -Output Detailed
```
Expected: 3 new tests PASS. All other tests stay green.

- [ ] **Step 5: Commit**

```powershell
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(cprompt): summary p50/p95 eval rate + median eval count"
```

---

## Task 7: Extend `cstats.ps1` output

**Files:**
- Modify: `cstats.ps1` (insert three lines after the existing summary block)

- [ ] **Step 1: Update `cstats.ps1`**

Replace the section from line 29 (the `Avg xml/input:` line) onwards through the end of the file with:

```powershell
Write-Host ("Avg xml/input: {0:N2}" -f $summary.AvgCompressionRatio)

# Compiler eval-rate stats — emit only when at least one entry has them. We
# detect "has data" by checking the median count, which is the only field
# computed from raw counts (and would be 0 if no entry contributed).
if ($summary.CompilerEvalCountMedian -gt 0) {
    Write-Host ("Compiler eval/s p50: {0:N2}" -f $summary.CompilerEvalRateP50)
    Write-Host ("Compiler eval/s p95: {0:N2}" -f $summary.CompilerEvalRateP95)
    Write-Host ("Compiler tokens out (median): {0}" -f $summary.CompilerEvalCountMedian)
}

Write-Host ''
Write-Host 'Mode counts:'
foreach ($mode in ($summary.ModeCounts.Keys | Sort-Object)) {
    Write-Host ("  {0,-12} {1}" -f $mode, $summary.ModeCounts[$mode])
}
```

- [ ] **Step 2: Hand-verify output by running cstats on a temp metrics file**

Run:
```powershell
$tmp = New-TemporaryFile
@'
{"ts":"2026-05-19T10:00:00Z","model":"prompt-opt","mode":"passthrough","totalMs":8200,"inputChars":40,"xmlChars":220,"compilerEval":{"evalRate":18.2,"evalCount":144}}
{"ts":"2026-05-19T10:01:00Z","model":"prompt-opt","mode":"passthrough","totalMs":7900,"inputChars":42,"xmlChars":210,"compilerEval":{"evalRate":20.1,"evalCount":150}}
'@ | Set-Content -LiteralPath $tmp -Encoding UTF8

./cstats.ps1 -Path $tmp.FullName
Remove-Item $tmp -Force
```
Expected output contains:
```
Compiler eval/s p50: 18.20
Compiler eval/s p95: 20.10
Compiler tokens out (median): 144
```

- [ ] **Step 3: Verify cstats on an old metrics file (no eval data) skips the new lines**

Run:
```powershell
$tmp = New-TemporaryFile
@'
{"ts":"2026-05-13T10:00:00Z","model":"prompt-opt","mode":"passthrough","totalMs":8200,"inputChars":40,"xmlChars":220}
'@ | Set-Content -LiteralPath $tmp -Encoding UTF8

./cstats.ps1 -Path $tmp.FullName
Remove-Item $tmp -Force
```
Expected: no `Compiler eval/s` lines in output (older metrics file remains valid).

- [ ] **Step 4: Commit**

```powershell
git add cstats.ps1
git commit -m "feat(cstats): show compiler eval/s p50/p95 + median tokens"
```

---

## Task 8: Full-suite verification, push, PR

- [ ] **Step 1: Run the full test suite**

Run:
```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Tests -Output Detailed
```
Expected: All tests PASS. Capture the totals (`Tests Passed: N, Failed: 0`).

- [ ] **Step 2: Skim diff for unintended changes**

Run:
```powershell
git diff main...HEAD --stat
git diff main...HEAD -- cprompt.psm1 c.ps1 cstats.ps1
```
Verify: no unrelated edits, no commented-out leftover code, no `Write-Host "DEBUG ..."` strays.

- [ ] **Step 3: Verify backward-compat smoke**

Hand-run `c.ps1` against a real ollama (skip if ollama unavailable on the machine):

```powershell
./c.ps1 -Raw "sistema ecs unity 3d game"
Get-Content "$env:USERPROFILE/.cprompt/metrics.jsonl" -Tail 1
```
Expected: `compilerEval` (and likely `refinerEval`) keys present in the last JSONL line, populated with numbers. Older entries in the file remain readable.

- [ ] **Step 4: Push branch and open PR**

Branch already exists: `feat/metrics-v2-eval-rate`.

```powershell
git push -u origin feat/metrics-v2-eval-rate
gh pr create --title "feat(metrics): capture Ollama eval rate per run" --body "$(cat <<'EOF'
## Summary
- Adds `ConvertFrom-OllamaVerboseStats` parser + `-CaptureStats` switch on `Invoke-OllamaModel` (Process-based capture so PS 5.1 doesn't mangle native stderr).
- Wires per-run refiner/compiler eval stats into `~/.cprompt/metrics.jsonl` as opt-in `refinerEval` / `compilerEval` keys (absent on cache hits + refiner-bypass paths).
- Extends `Get-MetricsSummary` + `cstats.ps1` with `Compiler eval/s p50`, `p95`, and median tokens out — gated on at least one entry having data.

Spec: `docs/superpowers/specs/2026-05-17-metrics-v2-eval-rate-design.md`

## Test plan
- [ ] Pester unit tests pass: parser regex coverage, summary percentile math, mixed-presence entries
- [ ] Pester integration tests pass: stats land on `-NoRefine`, both stats land on passthrough, cache-hit run has refinerEval-only
- [ ] Backward-compat: `Invoke-OllamaModel` without `-CaptureStats` returns a string (legacy callers unaffected)
- [ ] Old metrics files (no eval keys) parse fine and `cstats` skips the new lines
EOF
)"
```

If `gh pr create` times out (known issue on this host), open via `https://github.com/hhthunderbird/TRANSLaiTOR/pull/new/feat/metrics-v2-eval-rate`.

- [ ] **Step 5: Update memory after merge**

After PR merges, update `~/.claude/projects/C--Projetos-TRANSLaiTOR/memory/project_resume_state.md`:
- Bump `main` to the new HEAD sha.
- Append new PR # to merged-PR list.
- Move "Metrics v2 — eval rate" out of in-flight; mark sub-item done; the remaining v2 sub-items (Claude API token usage on `-Send`, cold-start flag, `cstats -Since` / `-By mode`) stay as open follow-ups.

---

## Self-Review

**Spec coverage:**
- §Architecture/`Invoke-OllamaModel` → Task 2 ✓
- §Architecture/`ConvertFrom-OllamaVerboseStats` → Task 1 ✓
- §Architecture/c.ps1 metrics wiring → Task 4 ✓
- §Architecture/cstats surface → Task 6 + Task 7 ✓
- §Data shape (opt-in keys, additive) → Task 4 step 4 ✓
- §Tests/unit (parser cases + summary cases) → Tasks 1 + 6 ✓
- §Tests/integration (compiler stats, refiner+compiler, cache-hit absence) → Task 5 ✓
- §Risks (NativeCommandError on `2>$file`, ANSI spinner, stderr capture timing) → Task 2 step 3 covers all three (Process API, Remove-AnsiEscapes pre-parse, WaitForExit guarantees flush).

**Placeholder scan:** No "TBD", "implement later", "similar to Task N", "add appropriate error handling". Every code step shows exact code.

**Type/name consistency:**
- Function name `ConvertFrom-OllamaVerboseStats` used in Task 1 (def), Task 2 step 3 (caller), Task 6 (n/a — summary reads hashtable keys), tests.
- Switch name `-CaptureStats` used in Task 2 (def), Task 4 steps 2 & 3 (callers), test in Task 2.
- Returned property names `.Text` / `.Stats` consistent across Task 2 def and Task 4 callers.
- Stats hashtable keys (`promptEvalCount`, `promptEvalDurationMs`, `evalCount`, `evalDurationMs`, `evalRate`) match spec and are referenced consistently in summary + cstats tasks.
- Summary field names `CompilerEvalRateP50`, `CompilerEvalRateP95`, `CompilerEvalCountMedian` match between Task 6 (def) and Task 7 (caller).
- Entry keys `refinerEval` / `compilerEval` match Task 4 (writer), Task 5 (integration assertions), Task 6 (reader).
