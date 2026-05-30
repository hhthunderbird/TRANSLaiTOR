# Conversational / Continuation Bypass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the prompt-opt compiler from hallucinating task specs for pure continuation prompts (e.g. "vamos continuar de onde paramos") by detecting them and bypassing the pipeline to raw passthrough.

**Architecture:** New deterministic discriminator `Test-InputIsConversational` in `cprompt.psm1`, curated whole-prompt phrase list (precision over recall). Wired into both `c.ps1` (new bypass stage → empty `-Raw` stdout / notice in interactive) and `c-autorefine.ps1` (cheap pre-filter → `exit 0` before ollama spawn). Bypass = raw passthrough; no synthetic XML.

**Tech Stack:** PowerShell 5.1, Pester v5.

---

### Task 1: `Test-InputIsConversational` detector (TDD)

**Files:**
- Modify: `cprompt.psm1` (add function after `Test-InputIsErrorLog` at line 810; add to `Export-ModuleMember` list at line 896)
- Test: `Tests/cprompt.Tests.ps1` (new `Describe` block, append after existing blocks)

- [ ] **Step 1: Write the failing test**

Append to `Tests/cprompt.Tests.ps1`:

```powershell
Describe 'Test-InputIsConversational' {
    It 'returns true for pure continuation imperatives' {
        $positives = @(
            'vamos continuar de onde paramos',
            'vamos continuar',
            'vamos na ordem',
            'continuar de onde paramos',
            'pode seguir',
            'pode continuar',
            'próximo',
            'proximo',
            'prossiga',
            'segue',
            'lets continue',
            "let's continue",
            'continue where we left off',
            'pick up where we left off',
            'go on',
            'keep going'
        )
        foreach ($p in $positives) {
            Test-InputIsConversational -Text $p | Should -BeTrue -Because "'$p' is a pure continuation"
        }
    }

    It 'returns false when a task topic is present' {
        $negatives = @(
            'continua o parser',
            'continue the auth refactor',
            'vamos refatorar o cache',
            'adiciona testes ao modulo X',
            'next: implement retry logic',
            'vamos continuar a implementacao do parser de XML'
        )
        foreach ($n in $negatives) {
            Test-InputIsConversational -Text $n | Should -BeFalse -Because "'$n' carries a task topic"
        }
    }

    It 'returns false for status questions (owned by meta-query)' {
        Test-InputIsConversational -Text 'o que falta?' | Should -BeFalse
        Test-InputIsConversational -Text 'whats left?'  | Should -BeFalse
    }

    It 'returns false for empty or whitespace input' {
        Test-InputIsConversational -Text ''    | Should -BeFalse
        Test-InputIsConversational -Text '   ' | Should -BeFalse
        Test-InputIsConversational -Text $null | Should -BeFalse
    }

    It 'is case-insensitive and tolerates trailing punctuation' {
        Test-InputIsConversational -Text 'VAMOS CONTINUAR' | Should -BeTrue
        Test-InputIsConversational -Text 'vamos continuar.' | Should -BeTrue
        Test-InputIsConversational -Text 'lets continue!' | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester Tests/cprompt.Tests.ps1 -FullNameFilter '*Test-InputIsConversational*'`
Expected: FAIL — `The term 'Test-InputIsConversational' is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Insert in `cprompt.psm1` immediately after the `Test-InputIsErrorLog` function (before line 896 `Export-ModuleMember`):

```powershell
function Test-InputIsConversational {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    # Strip leading/trailing whitespace and trailing sentence punctuation so
    # 'vamos continuar.' and 'lets continue!' still match the anchored set.
    $t = $Text.Trim().TrimEnd('.', '!', '?', ' ')

    # Pure continuation / "carry on" imperatives, anchored to the WHOLE prompt.
    # Anything with a task topic noun after the verb fails the anchor and
    # therefore compiles. Status QUESTIONS are intentionally excluded — they
    # are owned by Test-InputIsMetaQuery, which runs first and is more useful.
    $phrases = @(
        'vamos continuar de onde paramos',
        'continuar de onde paramos',
        'vamos continuar',
        'vamos na ordem',
        'pode continuar',
        'pode seguir',
        'prossiga',
        'segue',
        'continua',
        'pr[oó]ximo',
        'continue where we left off',
        'pick up where we left off',
        "let'?s continue",
        'go on',
        'keep going'
    )
    $pattern = '(?i)^\s*(' + ($phrases -join '|') + ')\s*$'
    return [bool]($t -match $pattern)
}
```

Add `Test-InputIsConversational` to the `Export-ModuleMember -Function` list (after `Test-InputIsErrorLog,` on line 925).

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester Tests/cprompt.Tests.ps1 -FullNameFilter '*Test-InputIsConversational*'`
Expected: PASS (all 5 `It` blocks green).

Note on `next: implement retry logic` negative: it does not match (text after the anchor), so it compiles — correct. `vamos continuar a implementacao...` also fails the anchor — correct.

- [ ] **Step 5: Commit**

```bash
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(bypass): add Test-InputIsConversational discriminator"
```

---

### Task 2: `c.ps1` bypass stage (TDD)

**Files:**
- Modify: `c.ps1` (add stage after error-log block at lines 202-210; add interactive output branch near lines 390-436)
- Test: `Tests/c.Tests.ps1` (new `Describe` block, append after the `-MetaQuery` block ~line 266)

- [ ] **Step 1: Write the failing test**

Append to `Tests/c.Tests.ps1`:

```powershell
Describe 'c.ps1 conversational bypass' {
    It 'emits empty stdout for a continuation prompt under -Raw (no ollama)' {
        $tmpHome = Join-Path $TestDrive 'home-conv-raw'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        # PathOverride hides ollama: bypass must not need the compiler at all.
        $safePath = Split-Path (Get-Command powershell.exe).Source
        $res = Invoke-CScript -Args @('-Raw', 'vamos continuar de onde paramos') -IsolatedHome $tmpHome -PathOverride $safePath
        $res.ExitCode | Should -Be 0
        $res.StdOut.Trim() | Should -BeNullOrEmpty
    }

    It 'records mode=conversational in metrics' {
        $tmpHome = Join-Path $TestDrive 'home-conv-metric'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $safePath = Split-Path (Get-Command powershell.exe).Source
        $res = Invoke-CScript -Args @('-Raw', 'vamos na ordem') -IsolatedHome $tmpHome -PathOverride $safePath
        $res.ExitCode | Should -Be 0
        $metricsPath = Join-Path $stateDir 'metrics.jsonl'
        $lastLine = Get-Content $metricsPath -Tail 1 -Encoding utf8
        $metric = $lastLine | ConvertFrom-Json
        $metric.mode | Should -Be 'conversational'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester Tests/c.Tests.ps1 -FullNameFilter '*conversational bypass*'`
Expected: FAIL — without the bypass, `c.ps1` tries the compiler, ollama is hidden by `-PathOverride`, exit code 2 ("ollama nao encontrado"); stdout not empty / mode != conversational.

- [ ] **Step 3: Write minimal implementation**

In `c.ps1`, insert a new stage immediately after the error-log block (after line 210, before the `if (-not $skipRefiner)` block at line 212):

```powershell
# Conversational stage: pure continuation prompts ("vamos continuar de onde
# paramos") carry no task topic. The compiler would be forced to invent one,
# so bypass the whole pipeline — raw passthrough. No synthetic XML.
if (-not $skipCompiler -and (Test-InputIsConversational -Text $userInput)) {
    if (-not $Raw) {
        Write-Host "(prompt conversacional - sem destilacao)" -ForegroundColor DarkGray
    }
    $metricMode   = 'conversational'
    $skipRefiner  = $true
    $skipCompiler = $true
    # $xml stays $null → -Raw emits empty stdout; interactive branch (below)
    # echoes the raw text without clipboard write.
}
```

Then guard the final output tail. Replace the `if ($Raw) { ... } else { ... }` clipboard tail (lines 390-436) so a `$null` xml in conversational mode does not print a blank XML / copy an empty clipboard. Change the non-`$Send`, non-`$Raw` terminal branch:

Find (around line 433-436):

```powershell
} else {
    $xml | Set-Clipboard
    Write-Host "copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude." -ForegroundColor Green
}
```

Replace with:

```powershell
} elseif ($metricMode -eq 'conversational') {
    # Nothing distilled — echo the raw text, no clipboard write.
    Write-Output $rawInput
} else {
    $xml | Set-Clipboard
    Write-Host "copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude." -ForegroundColor Green
}
```

Also guard the `Write-Host "`n$xml`n"` at line 395 so it does not print an empty envelope in conversational mode. Find:

```powershell
Write-Host "`n$xml`n" -ForegroundColor Gray
```

Replace with:

```powershell
if ($metricMode -ne 'conversational') {
    Write-Host "`n$xml`n" -ForegroundColor Gray
}
```

(The `-Raw` path at line 390 already does `Write-Output $xml`; with `$xml = $null` that writes nothing — no change needed there.)

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester Tests/c.Tests.ps1 -FullNameFilter '*conversational bypass*'`
Expected: PASS (both `It` blocks).

- [ ] **Step 5: Run the full c.ps1 suite for regressions**

Run: `Invoke-Pester Tests/c.Tests.ps1`
Expected: PASS, no regressions in meta-query / error-log / zero-signal blocks.

- [ ] **Step 6: Commit**

```bash
git add c.ps1 Tests/c.Tests.ps1
git commit -m "feat(bypass): conversational stage in c.ps1 (raw passthrough)"
```

---

### Task 3: Hook pre-filter (TDD)

**Files:**
- Modify: `hooks/c-autorefine.ps1` (add module import + check after line 49 single-token regex)
- Test: `Tests/c.AutorefineHook.Tests.ps1` (new `Describe` block)

- [ ] **Step 1: Write the failing test**

Append to `Tests/c.AutorefineHook.Tests.ps1` (reuse the `$script:hookCopy` / `Invoke-Hook` harness defined in its `BeforeAll`; mirror the existing transcript-parsing `Describe` invocation style):

```powershell
Describe 'c-autorefine.ps1 conversational bypass' {
    It 'exits 0 with no output for a multi-word continuation prompt' {
        $payload = @{ prompt = 'vamos continuar de onde paramos' } | ConvertTo-Json -Compress
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:hookCopy)
        $out = $payload | & powershell.exe @psArgs 2>$null
        $LASTEXITCODE | Should -Be 0
        ($out | Out-String).Trim() | Should -BeNullOrEmpty
    }
}
```

(If the file's `BeforeAll` exposes a helper like `Invoke-Hook -Prompt`, use that instead of the inline `powershell.exe` call — match the existing pattern in the file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester Tests/c.AutorefineHook.Tests.ps1 -FullNameFilter '*conversational bypass*'`
Expected: FAIL — hook currently spawns c.ps1; the prompt is >30 chars and not a single-token reply, so without the new filter it does not cleanly bypass at the hook layer (output depends on ollama availability; the assertion of empty output fails).

- [ ] **Step 3: Write minimal implementation**

In `hooks/c-autorefine.ps1`, immediately after the single-token conversational check (line 49 `if ($trim -match $conversational) { exit 0 }`), add:

```powershell
    # Multi-word continuation prompts ("vamos continuar de onde paramos")
    # carry no task topic; bypass before spawning ollama. Reuse the module
    # discriminator as the single source of truth. Fail-open on import error.
    try { Import-Module 'C:\Projetos\TRANSLaiTOR\cprompt.psm1' -Force -ErrorAction Stop } catch {}
    if ((Get-Command Test-InputIsConversational -ErrorAction SilentlyContinue) `
        -and (Test-InputIsConversational -Text $trim)) { exit 0 }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester Tests/c.AutorefineHook.Tests.ps1 -FullNameFilter '*conversational bypass*'`
Expected: PASS.

- [ ] **Step 5: Run the full hook suite for regressions**

Run: `Invoke-Pester Tests/c.AutorefineHook.Tests.ps1`
Expected: PASS — stream-isolation and transcript-parsing blocks still green.

- [ ] **Step 6: Commit**

```bash
git add hooks/c-autorefine.ps1 Tests/c.AutorefineHook.Tests.ps1
git commit -m "feat(bypass): hook pre-filter reuses Test-InputIsConversational"
```

---

### Task 4: End-to-end smoke + full suite + PR

**Files:** none (verification only)

- [ ] **Step 1: Full Pester run**

Run: `Invoke-Pester Tests/`
Expected: all tests pass (baseline was 434/434; expect 434 + new `It` blocks).

- [ ] **Step 2: Live smoke with -NoCache (the original failing prompt)**

The garbled XML for `vamos continuar de onde paramos` is CACHED (PR #52 key = Model+Text+Context). Smoke MUST use `-NoCache` or cached garbage masks the fix.

Run: `pwsh -NoProfile -File c.ps1 -Raw -NoCache 'vamos continuar de onde paramos'`
Expected: empty stdout (bypass; no `<task>` envelope).

Contrast — a real task still compiles:
Run: `pwsh -NoProfile -File c.ps1 -Raw -NoCache 'continua o parser de XML'`
Expected: a `<task>...</task><context>...</context><constraints>...</constraints>` envelope.

- [ ] **Step 3: Pre-push diff review**

Run: `git diff main...feat/conversational-bypass`
Confirm: only `cprompt.psm1`, `c.ps1`, `hooks/c-autorefine.ps1`, the three test files, and the two spec docs changed. No stray edits.

- [ ] **Step 4: Push + PR**

```bash
git push -u origin feat/conversational-bypass
gh pr create --title "feat: conversational/continuation compiler bypass" --body "..."
```

PR body covers: compiler-not-refiner framing, precision-over-recall, dual-layer wiring (hook + c.ps1), `-NoCache` smoke result.

---

## Self-Review

**Spec coverage:**
- `Test-InputIsConversational` (spec → Components) → Task 1. ✓
- `c.ps1` bypass stage + interactive output (spec → Components, "Interactive out" decision) → Task 2. ✓
- Hook pre-filter via module import (spec → Components, fail-open) → Task 3. ✓
- Status-question exclusion (spec edit) → Task 1 negative test. ✓
- Cache `-NoCache` smoke gotcha (spec → Testing) → Task 4 Step 2. ✓
- No synthetic XML (spec → Approach) → bypass leaves `$xml=$null`; no `Format-*` added. ✓

**Placeholder scan:** PR body `--body "..."` in Task 4 Step 4 is the only deferred content (composed at push time from the listed bullet points) — acceptable, not a code placeholder.

**Type consistency:** `Test-InputIsConversational -Text` signature identical across Task 1 (def), Task 2 (`c.ps1` call), Task 3 (hook call). `$metricMode -eq 'conversational'` string identical in Task 2 stage + both output branches and Task 2 metric assertion.
