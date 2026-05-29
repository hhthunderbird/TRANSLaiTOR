# Refiner Eval Set Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand `Tests/fixtures/refiner-corpus.json` from 8 to ~28 cases sourced from real production patterns, add an additive `acceptableModes` schema field for borderline inputs, regenerate `bench-results/baseline.json` via a new utility script, and lock all of it down with new Pester coverage.

**Architecture:** Schema is additive (`acceptableModes` optional; absent = current behaviour). `Get-RefinerRegressions` is updated to sum hits across acceptable modes when the field is present. A new `Tests/Invoke-RefinerBaseline.ps1` utility is the single source of truth for regenerating `baseline.json`, runs N=20 trials/case for low variance, and matches the existing baseline schema (`startedAt`, `endedAt`, `durationSec`, `refinerModel`, `trialsPerCase`, `corpusVersion`, `cases[]` with `modeCounts`, `qCountCounts`, `latencyMsP50`, `latencyMsP95`, `samples`).

**Tech Stack:** PowerShell 5.1 (Windows), Pester 5.7.1, Ollama (`prompt-refiner` model built from `Modelfile.refiner`).

**Spec:** `docs/superpowers/specs/2026-05-28-refiner-eval-set-design.md` (branch `spec/refiner-eval-set`).

---

## File map

| File | Action | Responsibility |
|------|--------|----------------|
| `Tests/fixtures/refiner-corpus.json` | Modify | Add 20 new cases, bump version to 2, document `acceptableModes` in `notes` and tag convention |
| `cprompt.psm1` — `Get-RefinerRegressions` | Modify (~lines 732–790) | Read optional `acceptableModes`; sum hits across all acceptable modes; back-compat when field absent |
| `Tests/Refiner.Quality.Tests.ps1` | Modify (~line 99 `It "hits expected mode"`) | Hit predicate reads `acceptableModes` when present |
| `Tests/cprompt.Tests.ps1` | Modify | Add `Describe 'refiner-corpus.json schema'` + two `It` blocks under existing `Describe 'Get-RefinerRegressions'` |
| `Tests/Invoke-RefinerBaseline.ps1` | Create | Regen utility: read corpus, run N trials/case, emit baseline.json matching existing schema |
| `bench-results/baseline.json` | Regenerate | Created by running the new utility with N=20 against the expanded corpus |

---

## Pre-flight

- [ ] **Step 0: Branch off main**

Run:
```
git checkout main
git pull --ff-only
git checkout -b chore/refiner-eval-expansion
```
Expected: switched to a new branch `chore/refiner-eval-expansion`.

---

### Task 1: Add fixture schema validation tests (current 8-case corpus must still pass)

Establish the schema-validation safety net BEFORE expanding the corpus, so every subsequent case addition is gated.

**Files:**
- Modify: `Tests/cprompt.Tests.ps1` (append new Describe at end of file)

- [ ] **Step 1: Write the new Describe block — schema validation**

Append to the end of `Tests/cprompt.Tests.ps1`:

```powershell
Describe 'refiner-corpus.json schema' {
    BeforeAll {
        $script:corpusPath = Join-Path $PSScriptRoot 'fixtures/refiner-corpus.json'
        $script:corpus = Get-Content -LiteralPath $script:corpusPath -Raw -Encoding utf8 | ConvertFrom-Json
    }

    It 'has a numeric version field' {
        $script:corpus.version | Should -BeOfType [int]
    }

    It 'has a non-empty cases array' {
        @($script:corpus.cases).Count | Should -BeGreaterThan 0
    }

    It 'every case has a non-empty id' {
        foreach ($c in $script:corpus.cases) {
            [string]::IsNullOrWhiteSpace([string]$c.id) | Should -BeFalse -Because "case id missing: $($c | ConvertTo-Json -Compress)"
        }
    }

    It 'case ids are unique' {
        $ids = @($script:corpus.cases | ForEach-Object { [string]$_.id })
        ($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'every case has a non-empty input' {
        foreach ($c in $script:corpus.cases) {
            [string]::IsNullOrWhiteSpace([string]$c.input) | Should -BeFalse -Because "input missing for case '$($c.id)'"
        }
    }

    It 'every expectedMode is one of passthrough|questions|rejected' {
        foreach ($c in $script:corpus.cases) {
            [string]$c.expectedMode | Should -BeIn @('passthrough','questions','rejected') -Because "case '$($c.id)' has invalid expectedMode"
        }
    }

    It 'when acceptableModes is present it is an array containing expectedMode and only valid live modes' {
        foreach ($c in $script:corpus.cases) {
            if (-not $c.PSObject.Properties['acceptableModes']) { continue }
            if ($null -eq $c.acceptableModes) { continue }
            $am = @($c.acceptableModes | ForEach-Object { [string]$_ })
            $am | Should -Not -BeNullOrEmpty -Because "case '$($c.id)' has empty acceptableModes"
            foreach ($m in $am) {
                $m | Should -BeIn @('passthrough','questions') -Because "case '$($c.id)' has invalid acceptableMode '$m'"
            }
            $am | Should -Contain ([string]$c.expectedMode) -Because "case '$($c.id)' acceptableModes must contain expectedMode '$($c.expectedMode)'"
        }
    }
}
```

- [ ] **Step 2: Run the new Describe — must pass on the unchanged 8-case fixture**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*refiner-corpus.json schema*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```
Expected: 7/7 pass. The current fixture has version=1 (numeric), 8 unique-id non-empty cases, all expectedMode in {passthrough, questions, rejected}, no `acceptableModes` field anywhere (the last `It` short-circuits on absence).

- [ ] **Step 3: Commit**

Run:
```
git add Tests/cprompt.Tests.ps1
git commit -m "test: add refiner-corpus.json schema validation describe

Establish schema gating before the corpus expansion. Asserts version
is numeric, ids are unique and non-empty, every expectedMode is
valid, and acceptableModes (when present) is an array of valid
live modes containing expectedMode.

7/7 pass against the unchanged 8-case fixture (acceptableModes
absent everywhere; the optional-field check short-circuits).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Bump corpus version 1 → 2 and document `acceptableModes`

**Files:**
- Modify: `Tests/fixtures/refiner-corpus.json` (lines 1–3)

- [ ] **Step 1: Update the version and the top-of-file `notes` string**

Edit `Tests/fixtures/refiner-corpus.json`. Replace lines 1–3:

OLD:
```json
{
  "version": 1,
  "notes": "Curated inputs for refiner quality benchmark. expectedMode: passthrough | questions | rejected (caught by zero-signal pre-gate). Edit when refiner behavior intentionally changes; do not mutate to chase a flaky run.",
```

NEW:
```json
{
  "version": 2,
  "notes": "Curated inputs for refiner quality benchmark. expectedMode (required): passthrough | questions | rejected (caught by zero-signal pre-gate). acceptableModes (optional): array of modes that count as a hit (default [expectedMode]); MUST contain expectedMode and only values in {passthrough, questions}. Use acceptableModes only when (1) the input has no clear missing slot, (2) PR #48 probe observed the refiner picking the alternate mode, AND (3) the case has the `borderline` tag. tags is a free-form convention: camelcase | mid-conv | error-log | file-path | english | pt-en-mix | long-input | borderline | concrete | vague | stack-named | scope-named | stack-missing | scope-missing | zero-signal | pre-gate. Edit when refiner behavior intentionally changes; do not mutate to chase a flaky run. Regenerate bench-results/baseline.json via Tests/Invoke-RefinerBaseline.ps1 after editing.",
```

- [ ] **Step 2: Verify the schema tests still pass**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*refiner-corpus.json schema*'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: 7/7 pass (version is still numeric `2`; no other change).

- [ ] **Step 3: Commit**

Run:
```
git add Tests/fixtures/refiner-corpus.json
git commit -m "chore(corpus): bump version 1->2, document acceptableModes and tags

Notes block now covers the optional acceptableModes field (with the
three admission criteria from the spec) and lists the tag
convention. No case data changed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: TDD — `Get-RefinerRegressions` reads `acceptableModes`

**Files:**
- Modify: `Tests/cprompt.Tests.ps1` (under existing `Describe 'Get-RefinerRegressions'` at ~line 788)
- Modify: `cprompt.psm1` — `Get-RefinerRegressions` (lines 732–790)

- [ ] **Step 1: Write the two failing `It` blocks under `Describe 'Get-RefinerRegressions'`**

Open `Tests/cprompt.Tests.ps1`, find `Describe 'Get-RefinerRegressions'`. Inside that Describe, append these two `It` blocks (before its closing `}`):

```powershell
    It 'sums baseline hits across acceptableModes and treats fresh hit in any acceptable mode as success' {
        # Baseline case: borderline — modeCounts split 6 passthrough / 4 questions.
        # expectedMode is passthrough, but acceptableModes accepts both.
        $baselineCase = [pscustomobject]@{
            id              = 'borderline-test'
            input           = 'something borderline'
            expectedMode    = 'passthrough'
            acceptableModes = @('passthrough','questions')
            trials          = 10
            modeCounts      = [pscustomobject]@{
                passthrough = 6
                questions   = 4
                invalid     = 0
            }
        }
        # Fresh distribution: 10/10 questions — falls entirely outside expectedMode
        # but fully inside acceptableModes. Must NOT be flagged as a regression.
        $fresh = @{}
        $fresh['borderline-test'] = 1..10 | ForEach-Object {
            [pscustomobject]@{ Mode = 'questions'; QCount = 1 }
        }

        $failures = @(Get-RefinerRegressions `
            -BaselineCases @($baselineCase) `
            -FreshDistributions $fresh `
            -DropThreshold 0.40)

        $failures.Count | Should -Be 0
    }

    It 'flags regression when fresh distribution lands outside all acceptable modes' {
        $baselineCase = [pscustomobject]@{
            id              = 'borderline-flag'
            input           = 'something borderline'
            expectedMode    = 'passthrough'
            acceptableModes = @('passthrough','questions')
            trials          = 10
            modeCounts      = [pscustomobject]@{
                passthrough = 6
                questions   = 4
                invalid     = 0
            }
        }
        # Fresh distribution: 10/10 invalid — outside every acceptable mode.
        $fresh = @{}
        $fresh['borderline-flag'] = 1..10 | ForEach-Object {
            [pscustomobject]@{ Mode = 'invalid'; QCount = 0 }
        }

        $failures = @(Get-RefinerRegressions `
            -BaselineCases @($baselineCase) `
            -FreshDistributions $fresh `
            -DropThreshold 0.40)

        $failures.Count | Should -Be 1
        $failures[0].id | Should -Be 'borderline-flag'
    }
```

- [ ] **Step 2: Run the two new tests — they MUST fail**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*Get-RefinerRegressions*sums baseline hits*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```
Then again with FullName `'*Get-RefinerRegressions*flags regression when fresh*'`.

Expected: BOTH FAIL. The first one fails because current `Get-RefinerRegressions` measures hits only against `expectedMode=passthrough`, so 10/10 questions reads as fresh rate 0% and the drop (60% − 0% = 60%) exceeds the 0.40 threshold, producing 1 failure (test expects 0). The second one is borderline — current code would also flag it (correctly, since fresh is 0% even for expectedMode), but the test will pass only after the update because we need both cases to share the new code path.

- [ ] **Step 3: Update `Get-RefinerRegressions` to read `acceptableModes`**

Open `cprompt.psm1`. Replace the whole function body (the `function Get-RefinerRegressions { ... }` block at lines 732–790) with:

```powershell
function Get-RefinerRegressions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $BaselineCases,
        [Parameter(Mandatory)] [hashtable]$FreshDistributions,
        [double]$DropThreshold = 0.40
    )

    $failures = @()
    foreach ($case in $BaselineCases) {
        $expected = [string]$case.expectedMode
        if ($expected -eq 'rejected') { continue }

        # acceptableModes (optional). When present, hits sum across all listed
        # modes. When absent, the function behaves exactly as before:
        # acceptable = [expectedMode].
        $acceptable = if ($case.PSObject.Properties['acceptableModes'] -and $case.acceptableModes) {
            @($case.acceptableModes | ForEach-Object { [string]$_ })
        } else {
            @($expected)
        }

        $baseTrials = [int]$case.trials
        if ($baseTrials -le 0) { continue }

        # Sum baseline hits across every acceptable mode.
        $baseHits = 0
        foreach ($m in $acceptable) {
            $prop = $case.modeCounts.PSObject.Properties[$m]
            if ($prop) { $baseHits += [int]$prop.Value }
        }
        $baseRate = $baseHits / $baseTrials

        if (-not $FreshDistributions.ContainsKey($case.id)) {
            $failures += [pscustomobject]@{
                id           = [string]$case.id
                reason       = 'fresh distribution missing'
                baselineRate = $baseRate
                freshRate    = $null
                drop         = $null
            }
            continue
        }

        $fresh = @($FreshDistributions[$case.id])
        if ($fresh.Count -le 0) {
            $failures += [pscustomobject]@{
                id           = [string]$case.id
                reason       = 'fresh distribution empty'
                baselineRate = $baseRate
                freshRate    = $null
                drop         = $null
            }
            continue
        }

        # Fresh hit = any trial whose mode is in the acceptable set.
        $freshHits = @($fresh | Where-Object { [string]$_.Mode -in $acceptable }).Count
        $freshRate = $freshHits / $fresh.Count
        $drop      = $baseRate - $freshRate

        if ($drop -gt $DropThreshold) {
            $failures += [pscustomobject]@{
                id           = [string]$case.id
                reason       = ("drop {0:P0} exceeds threshold {1:P0}" -f $drop, $DropThreshold)
                baselineRate = $baseRate
                freshRate    = $freshRate
                drop         = $drop
            }
        }
    }
    return $failures
}
```

- [ ] **Step 4: Run both new tests — they MUST pass**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*Get-RefinerRegressions*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```
Expected: ALL `Get-RefinerRegressions` tests pass (existing + 2 new). Existing tests use cases without `acceptableModes` and hit the fallback path — behaviour identical.

- [ ] **Step 5: Commit**

Run:
```
git add cprompt.psm1 Tests/cprompt.Tests.ps1
git commit -m "feat(cprompt): Get-RefinerRegressions reads optional acceptableModes

Sum baseline hits and fresh hits across every mode listed in
acceptableModes. When the field is absent on a baseline case,
acceptable defaults to [expectedMode] and behaviour is identical
to before.

Adds two Describe-internal It blocks proving (1) borderline case
with fresh in alternate-acceptable mode is NOT flagged, and (2)
borderline case with fresh fully outside acceptable IS flagged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update `Refiner.Quality.Tests.ps1` hit predicate

The bench test's "hits expected mode" `It` must also read `acceptableModes` so live cases with the field are evaluated correctly.

**Files:**
- Modify: `Tests/Refiner.Quality.Tests.ps1` (around line 99)

- [ ] **Step 1: Replace the `It "hits expected mode (<_.expectedMode>)..."` block**

Open `Tests/Refiner.Quality.Tests.ps1`. Find the `Describe 'Refiner statistical invariants'` block. Inside its `Context "case: <_.id>"`, replace the existing `It "hits expected mode..."` block with:

```powershell
        It "hits expected mode (<_.expectedMode>) in >=60% of trials" -Skip:($_.expectedMode -notin @('passthrough','questions')) {
            $accept = if ($_.PSObject.Properties['acceptableModes'] -and $_.acceptableModes) {
                @($_.acceptableModes | ForEach-Object { [string]$_ })
            } else {
                @([string]$script:ExpectedMode)
            }
            $hit  = @($script:Dist | Where-Object { [string]$_.Mode -in $accept }).Count
            $rate = $hit / $script:Trials
            Write-Host ("    [{0}] {1}={2}/{3} ({4:P0})" -f $script:CaseId, ($accept -join '|'), $hit, $script:Trials, $rate)
            ($rate -ge 0.6) | Should -Be $true
        }
```

- [ ] **Step 2: Run the Refiner bench — current 8 cases must still pass**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/Refiner.Quality.Tests.ps1'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: 27/27 pass. All existing cases have no `acceptableModes`, so `$accept` falls back to `@($script:ExpectedMode)` and the predicate is identical to before.

- [ ] **Step 3: Commit**

Run:
```
git add Tests/Refiner.Quality.Tests.ps1
git commit -m "test(refiner-bench): hit predicate reads acceptableModes when present

One-line change to the 'hits expected mode' It block. Cases
without the field fall back to a single-element list, so the 8
existing cases are unaffected (27/27 still pass).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Expand corpus — 5 CamelCase identifier cases

**Files:**
- Modify: `Tests/fixtures/refiner-corpus.json`

- [ ] **Step 1: Insert 5 cases before the existing `zero-signal-short` entry**

Open `Tests/fixtures/refiner-corpus.json`. Locate the existing `vague-improve` case (currently the last entry before the two `zero-signal-*` cases). Immediately after the closing `}` of `vague-improve` (before the line containing `zero-signal-short`), insert these 5 case objects (remember the comma after `vague-improve`'s closing brace if it isn't already there, and a trailing comma on the last new case so the existing `zero-signal-short` entry that follows is still valid JSON):

```json
    {
      "id": "camelcase-exam-membership-flag",
      "input": "ExamMembership Exam precisa ser flag para  permitir escolher vários",
      "expectedMode": "passthrough",
      "tags": ["camelcase", "concrete", "pt"]
    },
    {
      "id": "camelcase-toggle-event-button",
      "input": "ToggleEventButton não está disparando o evento ou o evento está incorreto ou alguma outra razão para o evento não estar chegando corretamente",
      "expectedMode": "passthrough",
      "tags": ["camelcase", "concrete", "pt"]
    },
    {
      "id": "camelcase-interactive-exam-manager-prefabs",
      "input": "Estou fazendo um experimento com o InteractiveExamManager carregando os exames a partir de prefabs, porém, ao iniciar o measure exam os botões para interação não apareceram ExamMembership",
      "expectedMode": "passthrough",
      "tags": ["camelcase", "concrete", "long-input", "pt"]
    },
    {
      "id": "camelcase-autohand-raycast",
      "input": "Em AutoHandSimulatorUIInteraction a interação com UI parece estar executando todos os controles em que o raycast atinge e isso está causando problemas, verifique",
      "expectedMode": "passthrough",
      "tags": ["camelcase", "concrete", "long-input", "pt"]
    },
    {
      "id": "camelcase-exam-profile-rules",
      "input": "voltando para a implementação e migração.\nExamProfile Visibility Rules e as outras Rules recebem uma lista de Memberships e possui e possui uma lista de regras, então todos os elementos dentro das rules atendem àquela lista de regras",
      "expectedMode": "passthrough",
      "tags": ["camelcase", "concrete", "long-input", "pt"]
    },
```

- [ ] **Step 2: Verify schema tests pass on the 13-case fixture**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*refiner-corpus.json schema*'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: 7/7 pass. Cases array now has 13 entries; ids are unique; new entries all have valid `expectedMode=passthrough`; none use `acceptableModes`.

- [ ] **Step 3: Commit**

Run:
```
git add Tests/fixtures/refiner-corpus.json
git commit -m "test(corpus): add 5 CamelCase identifier passthrough cases

ExamMembership, ToggleEventButton, InteractiveExamManager, AutoHand
SimulatorUIInteraction, ExamProfile Visibility Rules. Real-world
patterns that PR #48 probe found the pre-fix refiner misrouting.
All expectedMode=passthrough.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Expand corpus — 1 lang-keyword + 2 error-log + 1 git-op + 1 file-path-list cases

**Files:**
- Modify: `Tests/fixtures/refiner-corpus.json`

- [ ] **Step 1: Insert these 5 cases after the 5 CamelCase entries from Task 5**

Open `Tests/fixtures/refiner-corpus.json`. Immediately after the closing `}` of `camelcase-exam-profile-rules`, insert:

```json
    {
      "id": "keyword-go-cache-lru-short",
      "input": "quero implementar cache LRU em Go",
      "expectedMode": "passthrough",
      "tags": ["concrete", "stack-named", "pt"]
    },
    {
      "id": "error-log-nullref-multi-frame",
      "input": "NullReferenceException: Object reference not set to an instance of an object\nInteractiveMeasureTape_Body.UpdateUI () (at Assets/Scripts/InteractiveObjects/InteractiveMeasureTape_Body.cs:137)\nInteractiveMeasureTape_Body.UpdateDisplayValue () (at Assets/Scripts/InteractiveObjects/InteractiveMeasureTape_Body.cs:128)\nInteractiveMeasureTape_Body.UpdateAnimation () (at Assets/Scripts/InteractiveObjects/InteractiveMeasureTape_Body.cs:101)",
      "expectedMode": "passthrough",
      "tags": ["error-log", "stack-trace", "long-input", "concrete"]
    },
    {
      "id": "error-log-cs1061",
      "input": "Assets\\Scripts\\UI\\MainUIController.cs(193,51): error CS1061: 'ProgressIndicator' does not contain a definition for 'progressValue' and no accessible extension method 'progressValue' accepting a first argument of type 'ProgressIndicator' could be found (are you missing a using directive or an assembly reference?)",
      "expectedMode": "passthrough",
      "tags": ["error-log", "file-path", "concrete"]
    },
    {
      "id": "git-cleanup-and-list",
      "input": "Limpe os debug logs desnecessários e liste os commits",
      "expectedMode": "passthrough",
      "tags": ["git", "concrete", "pt"]
    },
    {
      "id": "file-path-list-commit",
      "input": "RASCALSkinnedMeshCollider.cs, RascalExtensions.cs   não vão\nTooltipGradientRenderPass*.mat não vai\no resto está ok\nfaça o commit",
      "expectedMode": "passthrough",
      "tags": ["file-path", "concrete", "pt"]
    },
```

- [ ] **Step 2: Verify schema tests pass on the 18-case fixture**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*refiner-corpus.json schema*'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: 7/7 pass.

- [ ] **Step 3: Commit**

Run:
```
git add Tests/fixtures/refiner-corpus.json
git commit -m "test(corpus): add lang-keyword, error-log, git-op, file-path cases

Five more passthrough cases from the eval-sample.json probe:
quero-implementar-cache-LRU-em-Go (lang keyword), two error-log
patterns (NullReferenceException multi-frame and CS1061 with file
path), a git cleanup-and-list, and a multi-line file-path commit
list. Schema validation green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Expand corpus — 3 mid-conversation borderline + 1 vague borderline (4 acceptableModes entries)

**Files:**
- Modify: `Tests/fixtures/refiner-corpus.json`

- [ ] **Step 1: Insert 4 cases after the entries from Task 6**

Open `Tests/fixtures/refiner-corpus.json`. After `file-path-list-commit`, insert:

```json
    {
      "id": "midconv-visual-companion",
      "input": "vamos continuar com o visual companion",
      "expectedMode": "passthrough",
      "acceptableModes": ["passthrough", "questions"],
      "tags": ["mid-conv", "borderline", "pt"]
    },
    {
      "id": "midconv-reavalie-injects",
      "input": "agora reavalie os Injects",
      "expectedMode": "passthrough",
      "acceptableModes": ["passthrough", "questions"],
      "tags": ["mid-conv", "borderline", "camelcase", "pt"]
    },
    {
      "id": "midconv-dropdown-enum-flag",
      "input": "Explicação aceita. E um dropdown selecionável como se fosse o de um enum-flag?",
      "expectedMode": "passthrough",
      "acceptableModes": ["passthrough", "questions"],
      "tags": ["mid-conv", "borderline", "pt"]
    },
    {
      "id": "vague-comece-investigacao",
      "input": "comece a investigação",
      "expectedMode": "questions",
      "acceptableModes": ["questions", "passthrough"],
      "tags": ["vague", "mid-conv", "borderline", "pt"]
    },
```

- [ ] **Step 2: Verify schema tests pass and `acceptableModes` validation kicks in**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*refiner-corpus.json schema*'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: 7/7 pass. The "acceptableModes when present" rule now actually fires on 4 cases: each is an array, every element is `passthrough` or `questions`, and `expectedMode` is in the array.

- [ ] **Step 3: Commit**

Run:
```
git add Tests/fixtures/refiner-corpus.json
git commit -m "test(corpus): add 4 borderline cases with acceptableModes

Three mid-conversation replies with concrete topics (visual
companion, reavalie Injects, dropdown enum-flag) and one
vague mid-conv (comece a investigacao). All four list both
modes in acceptableModes per the spec's admission criteria
(no clear missing slot + PR #48 probe observed both modes
+ borderline tag).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Expand corpus — 2 vague + 4 synthetic edge cases

**Files:**
- Modify: `Tests/fixtures/refiner-corpus.json`

- [ ] **Step 1: Insert 6 cases**

Open `Tests/fixtures/refiner-corpus.json`. After `vague-comece-investigacao`, insert:

```json
    {
      "id": "vague-ideia-vaga",
      "input": "ideia vaga",
      "expectedMode": "questions",
      "tags": ["vague", "scope-missing", "stack-missing", "pt"]
    },
    {
      "id": "vague-a-depois-followups",
      "input": "A, depois follow-ups",
      "expectedMode": "questions",
      "tags": ["vague", "scope-missing", "pt"]
    },
    {
      "id": "synth-english-spring-boot",
      "input": "fix the RedisConnectionPoolFactory leak in our Spring Boot service that only shows up after about 10000 requests",
      "expectedMode": "passthrough",
      "tags": ["english", "camelcase", "stack-named", "concrete"]
    },
    {
      "id": "synth-long-stack-trace-500",
      "input": "ArgumentNullException: Value cannot be null. (Parameter 'source')\n   at System.Linq.ThrowHelper.ThrowArgumentNullException(ExceptionArgument argument)\n   at System.Linq.Enumerable.Where[TSource](IEnumerable`1 source, Func`2 predicate)\n   at MedroomHub.Editor.MedroomHubWindow.DrawExams () (at Assets/Scripts/Editor/MedroomHub/MedroomHubWindow.cs:271)\n   at MedroomHub.Editor.MedroomHubWindow.OnGUI () (at Assets/Scripts/Editor/MedroomHub/MedroomHubWindow.cs:88)\n   at UnityEditor.HostView.OldOnGUI () (at /Users/bokken/build/output/unity/unity/Editor/Mono/HostView.cs:142)\n   at UnityEngine.UIElements.IMGUIContainer.DoOnGUI (UnityEngine.Event evt, UnityEngine.Matrix4x4 parentTransform, UnityEngine.Rect clippingRect, System.Boolean isComputingLayout, UnityEngine.Rect layoutSize, System.Action onGUIHandler)",
      "expectedMode": "passthrough",
      "tags": ["error-log", "stack-trace", "long-input", "english"]
    },
    {
      "id": "synth-pt-en-mix",
      "input": "bug no controller, vai dar TypeError no JSON.parse quando o backend manda undefined",
      "expectedMode": "passthrough",
      "tags": ["pt-en-mix", "concrete", "stack-named"]
    },
    {
      "id": "synth-bare-identifier",
      "input": "ExamMembership",
      "expectedMode": "passthrough",
      "acceptableModes": ["passthrough", "questions"],
      "tags": ["camelcase", "borderline", "bare-identifier", "pt"]
    },
```

- [ ] **Step 2: Verify schema tests pass on the 28-case fixture**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/cprompt.Tests.ps1'
$cfg.Filter.FullName = '*refiner-corpus.json schema*'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: 7/7 pass. Fixture now has exactly 28 cases (6 original live + 2 original rejected + 5 + 5 + 4 + 6).

- [ ] **Step 3: Commit**

Run:
```
git add Tests/fixtures/refiner-corpus.json
git commit -m "test(corpus): add 2 vague + 4 synthetic edge cases (final batch)

vague-ideia-vaga and vague-a-depois-followups deduplicate the
three ideia-vaga rows in eval-sample.json down to one. Synthetic
cases close coverage gaps the eval-sample doesn't reach: pure
English w/ identifier, long stack trace >500 chars, mixed PT/EN
concrete request, and a bare CamelCase identifier (borderline).

Corpus is now 28 cases (6 original live + 5 + 5 + 4 + 6 = 26
live + 2 rejected).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Create `Tests/Invoke-RefinerBaseline.ps1` — TDD with smoke test

**Files:**
- Modify: `Tests/Refiner.Quality.Tests.ps1` (append new Describe at end)
- Create: `Tests/Invoke-RefinerBaseline.ps1`

- [ ] **Step 1: Write the failing smoke test**

Append to the end of `Tests/Refiner.Quality.Tests.ps1`:

```powershell
Describe 'Invoke-RefinerBaseline smoke' -Tag 'Live' -Skip:(-not $available) {
    It 'produces a baseline.json that matches the documented schema' {
        $miniCorpusPath = Join-Path $TestDrive 'mini-corpus.json'
        $miniCorpus = @{
            version = 2
            notes   = 'smoke fixture'
            cases   = @(
                @{
                    id           = 'smoke-passthrough'
                    input        = 'cache lru em go com tamanho 1000 e ttl 30s'
                    expectedMode = 'passthrough'
                    tags         = @('concrete','stack-named')
                },
                @{
                    id           = 'smoke-rejected'
                    input        = '   '
                    expectedMode = 'rejected'
                    tags         = @('zero-signal')
                }
            )
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $miniCorpusPath -Value $miniCorpus -Encoding UTF8

        $outPath = Join-Path $TestDrive 'baseline-smoke.json'
        $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tests/Invoke-RefinerBaseline.ps1'

        & $script -Trials 2 -CorpusPath $miniCorpusPath -OutputPath $outPath -RefinerModel $script:RefinerModel -Force
        $LASTEXITCODE | Should -Be 0
        Test-Path $outPath | Should -BeTrue

        $baseline = Get-Content -LiteralPath $outPath -Raw -Encoding utf8 | ConvertFrom-Json
        $baseline.trialsPerCase | Should -Be 2
        $baseline.corpusVersion | Should -Be 2
        $baseline.refinerModel  | Should -Be $script:RefinerModel
        # rejected case is filtered out — baseline only contains live cases.
        @($baseline.cases).Count | Should -Be 1
        $case = $baseline.cases[0]
        $case.id                                 | Should -Be 'smoke-passthrough'
        $case.modeCounts.PSObject.Properties['passthrough'] | Should -Not -BeNullOrEmpty
        $case.modeCounts.PSObject.Properties['questions']   | Should -Not -BeNullOrEmpty
        $case.modeCounts.PSObject.Properties['invalid']     | Should -Not -BeNullOrEmpty
        @($case.samples).Count                   | Should -Be 2
    }
}
```

- [ ] **Step 2: Run the smoke test — it MUST fail**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/Refiner.Quality.Tests.ps1'
$cfg.Filter.FullName = '*Invoke-RefinerBaseline smoke*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```
Expected: FAIL with "The term 'C:\Projetos\TRANSLaiTOR\Tests\Invoke-RefinerBaseline.ps1' is not recognized..." (the script doesn't exist yet).

- [ ] **Step 3: Create `Tests/Invoke-RefinerBaseline.ps1`**

Write the file `Tests/Invoke-RefinerBaseline.ps1`:

```powershell
<#
.SYNOPSIS
    Regenerate bench-results/baseline.json by running the refiner against every
    live case in Tests/fixtures/refiner-corpus.json for N trials.
.DESCRIPTION
    Single source of truth for the refiner regression baseline. Rejected cases
    (expectedMode == 'rejected') are filtered out — they exercise the
    Test-InputIsZeroSignal pre-gate, not the refiner model. For every live case
    runs N trials, parses each output with Get-RefinerOutput, and aggregates
    modeCounts, qCountCounts, latency p50/p95 and the full samples list. Refuses
    to overwrite an existing OutputPath without -Force.
.EXAMPLE
    .\Tests\Invoke-RefinerBaseline.ps1
.EXAMPLE
    .\Tests\Invoke-RefinerBaseline.ps1 -Trials 5 -Force
#>
[CmdletBinding()]
param(
    [int]$Trials = 20,
    [string]$RefinerModel = 'prompt-refiner',
    [string]$CorpusPath  = (Join-Path $PSScriptRoot 'fixtures/refiner-corpus.json'),
    [string]$OutputPath  = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bench-results/baseline.json'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'cprompt.psm1') -Force

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "OutputPath exists: $OutputPath. Pass -Force to overwrite."
}

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) { throw "ollama not found on PATH." }
$list = (& ollama list 2>$null | Out-String)
if ($list -notmatch [regex]::Escape($RefinerModel)) {
    throw "Refiner model '$RefinerModel' not found in 'ollama list'. Build it first: ollama create $RefinerModel -f Modelfile.refiner"
}

$corpus = Get-Content -LiteralPath $CorpusPath -Raw -Encoding utf8 | ConvertFrom-Json
$liveCases = @($corpus.cases | Where-Object { [string]$_.expectedMode -ne 'rejected' })

$startedAt = Get-Date
$resultCases = @()
$i = 0
$total = $liveCases.Count
foreach ($case in $liveCases) {
    $i++
    Write-Host ("[{0}/{1}] {2}" -f $i, $total, $case.id) -ForegroundColor DarkGray

    $samples   = @()
    $modeCounts = [ordered]@{ passthrough = 0; questions = 0; invalid = 0 }
    $qCountCounts = [ordered]@{}
    $latencies = @()

    for ($t = 0; $t -lt $Trials; $t++) {
        $r = Invoke-OllamaModel -Text ([string]$case.input) -Model $RefinerModel -CaptureStats
        $rawOut = [string]$r.Text
        $stats  = $r.Stats
        $parsed = Get-RefinerOutput $rawOut
        if ($null -eq $parsed) {
            $mode = 'invalid'
            $qCount = 0
            $payload = $rawOut
        } else {
            $mode = [string]$parsed.Mode
            $qCount = if ($mode -eq 'questions') { @($parsed.Payload).Count } else { 0 }
            $payload = if ($mode -eq 'questions') { ($parsed.Payload -join ' || ') } else { [string]$parsed.Payload }
        }
        $modeCounts[$mode]++
        $key = [string]$qCount
        if ($qCountCounts.Contains($key)) { $qCountCounts[$key]++ } else { $qCountCounts[$key] = 1 }
        if ($stats -and $stats.PSObject.Properties['totalDurationMs']) {
            $latencies += [int]$stats.totalDurationMs
        }
        $samples += [pscustomobject]@{ mode = $mode; qCount = $qCount; payload = $payload }
    }

    $p50 = if ($latencies.Count -gt 0) { [int]($latencies | Sort-Object)[ [math]::Floor($latencies.Count * 0.50) ] } else { 0 }
    $p95Idx = [math]::Min($latencies.Count - 1, [math]::Floor($latencies.Count * 0.95))
    $p95 = if ($latencies.Count -gt 0) { [int]($latencies | Sort-Object)[$p95Idx] } else { 0 }

    $resultCases += [pscustomobject]@{
        id              = [string]$case.id
        input           = [string]$case.input
        expectedMode    = [string]$case.expectedMode
        acceptableModes = if ($case.PSObject.Properties['acceptableModes'] -and $case.acceptableModes) { @($case.acceptableModes | ForEach-Object { [string]$_ }) } else { $null }
        preGateBlocks   = [bool](Test-InputIsZeroSignal -Text ([string]$case.input))
        trials          = $Trials
        modeCounts      = $modeCounts
        qCountCounts    = $qCountCounts
        latencyMsP50    = $p50
        latencyMsP95    = $p95
        samples         = $samples
    }
}

$endedAt = Get-Date
$out = [ordered]@{
    startedAt      = $startedAt.ToString('o')
    endedAt        = $endedAt.ToString('o')
    durationSec    = [math]::Round(($endedAt - $startedAt).TotalSeconds, 2)
    refinerModel   = $RefinerModel
    trialsPerCase  = $Trials
    corpusVersion  = [int]$corpus.version
    cases          = $resultCases
}

$json = $out | ConvertTo-Json -Depth 8
$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

Write-Host ""
Write-Host ("baseline written: {0}" -f $OutputPath) -ForegroundColor Green
Write-Host ("  cases={0}  trials/case={1}  duration={2}s" -f $resultCases.Count, $Trials, $out.durationSec) -ForegroundColor DarkGray
exit 0
```

- [ ] **Step 4: Run the smoke test — it MUST pass**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/Refiner.Quality.Tests.ps1'
$cfg.Filter.FullName = '*Invoke-RefinerBaseline smoke*'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```
Expected: PASS. Smoke runs 2 trials on the single live case, baseline JSON has `trialsPerCase: 2`, `corpusVersion: 2`, `cases.Count: 1`, all three `modeCounts` keys present, `samples.Count: 2`.

- [ ] **Step 5: Commit**

Run:
```
git add Tests/Invoke-RefinerBaseline.ps1 Tests/Refiner.Quality.Tests.ps1
git commit -m "feat(tests): Tests/Invoke-RefinerBaseline.ps1 + smoke test

Single source of truth for regenerating bench-results/baseline.json.
Reads the corpus, runs N trials/case against the refiner, aggregates
modeCounts / qCountCounts / latency p50,p95 / samples, and emits a
baseline JSON matching the existing schema. Refuses to overwrite
without -Force. Filters rejected cases (those exercise the pre-gate,
not the refiner).

Smoke test (-Tag 'Live') runs the utility on a 1-case mini corpus
with Trials=2 and validates the output schema.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Regenerate `bench-results/baseline.json` against the expanded corpus

This is the actual cost step (~3 minutes of model calls). It runs the utility built in Task 9 against the corpus from Tasks 5–8.

**Files:**
- Regenerate: `bench-results/baseline.json`

- [ ] **Step 1: Ensure `prompt-refiner` is the current build of `Modelfile.refiner`**

Run:
```
ollama create prompt-refiner -f Modelfile.refiner
```
Expected: "success".

- [ ] **Step 2: Run the baseline utility with N=20**

Run:
```
.\Tests\Invoke-RefinerBaseline.ps1 -Trials 20 -Force
```
Expected (after ~3 minutes): progress lines `[1/26] camelcase-exam-membership-flag ...` through `[26/26] synth-bare-identifier ...`, then "baseline written: ...bench-results\baseline.json  cases=26  trials/case=20  duration=~170s".

- [ ] **Step 3: Eyeball the per-case hit rates in the new baseline**

Run:
```
$bl = Get-Content bench-results/baseline.json -Raw -Encoding utf8 | ConvertFrom-Json
$bl.cases | Select-Object id, expectedMode, @{n='pt';e={$_.modeCounts.passthrough}}, @{n='q';e={$_.modeCounts.questions}}, @{n='inv';e={$_.modeCounts.invalid}} | Format-Table
```
Expected: every passthrough case has `pt` >= 12/20 (60% threshold). Every questions case has `q` >= 12/20. Borderline cases (acceptableModes set) have `pt + q` >= 12/20. Document any case that fails to clear the threshold before committing — that's a signal the case needs rephrasing OR the labelling is wrong.

- [ ] **Step 4: Commit**

Run:
```
git add bench-results/baseline.json
git commit -m "chore(bench): regenerate baseline.json for 26-live-case corpus (N=20)

Generated via Tests/Invoke-RefinerBaseline.ps1 -Trials 20 -Force
against the expanded corpus from Tasks 5-8. Includes
acceptableModes per case (null when absent) so downstream tooling
can replay the same hit-rate calculation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Run the full Live bench against the new baseline

End-to-end validation: every case in the expanded corpus meets the bench's 80%-parse / 60%-hit / 40%-drop thresholds.

- [ ] **Step 1: Run the entire bench**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests/Refiner.Quality.Tests.ps1'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected (after ~4 minutes): all tests pass. Total around (2 zero-signal + 26 live × 3 invariant tests + 26 regression "collects fresh distribution" + 1 regression aggregate) = ~80 tests.

- [ ] **Step 2: Run the full Pester suite**

Run:
```
Import-Module Pester -RequiredVersion 5.7.1
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'Tests'
$cfg.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $cfg
```
Expected: all tests pass. New count: 317 (current main) + 7 schema validation + 2 Get-RefinerRegressions multi-acceptable + 1 baseline smoke + bench multi-It expansion ~= 380-ish. Final number will appear in the PR description.

- [ ] **Step 3: No commit (verification-only step)**

If any test failed, debug at its location. Do NOT modify the corpus to chase a flake — if a case fails the 60% hit threshold, accept the rate is below expectation and either (a) reword the case input to better match the intended pattern, (b) add the alternative mode to `acceptableModes` if the case is genuinely borderline per the spec's three admission criteria, or (c) remove the case if it turns out to be a poor signal.

---

### Task 12: Push and open PR

- [ ] **Step 1: Push the branch**

Run:
```
git push -u origin chore/refiner-eval-expansion
```
Expected: branch created on origin.

- [ ] **Step 2: Open the PR**

Run:
```
gh pr create --title "test(refiner): expand eval corpus to ~28 cases + acceptableModes + baseline utility" --body @'
## Summary
Implements `docs/superpowers/specs/2026-05-28-refiner-eval-set-design.md`.

- Corpus expanded from 8 to 28 cases (26 live + 2 rejected): 5 CamelCase identifiers, 1 lang-keyword, 2 error-logs, 1 git-op, 1 file-path commit list, 4 borderline mid-conv (with `acceptableModes`), 2 vague, 4 synthetic edge cases (English, long stack trace, PT/EN mix, bare identifier).
- Fixture schema bumped 1→2; new optional `acceptableModes` field — when present, the bench counts any listed mode as a hit (default `[expectedMode]`).
- `Get-RefinerRegressions` sums baseline and fresh hits across acceptable modes; existing 8 cases unaffected (fallback path).
- `Tests/Refiner.Quality.Tests.ps1` "hits expected mode" predicate updated to read `acceptableModes` when present.
- New utility `Tests/Invoke-RefinerBaseline.ps1` — single source of truth for regenerating `bench-results/baseline.json`. Refuses to overwrite without `-Force`. Runs at N=20 by default for low variance.
- `bench-results/baseline.json` regenerated against the new corpus (N=20).

## Tests
- `Describe 'refiner-corpus.json schema'` (7 new It blocks) — fixture validation.
- `Describe 'Get-RefinerRegressions'` (2 new It blocks) — multi-acceptable hit-counting in both pass and fail paths.
- `Describe 'Invoke-RefinerBaseline smoke'` (Live tag) — utility smoke at Trials=2 on a 1-case mini corpus.

## Test plan
- [x] Schema validation passes on the 28-case fixture.
- [x] `Get-RefinerRegressions` tests (old + new) pass.
- [x] Refiner.Quality bench runs against the regenerated baseline.
- [x] Full Pester suite green.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
'@
```
Expected: PR URL printed.

---

## Self-Review

**Spec coverage:**
- §"Goal" → Tasks 5–8 (corpus expand) + Task 9 (utility) + Task 10 (regen) cover the full goal.
- §"Non-goals" → No tasks address Approach 3 features, auto-curation, or cross-model framework. Correct: out of scope.
- §"Components table" → Every row mapped: corpus.json (Tasks 2,5–8), Get-RefinerRegressions (Task 3), Refiner.Quality.Tests (Task 4), Invoke-RefinerBaseline.ps1 (Task 9), baseline.json (Task 10), cprompt.Tests.ps1 (Task 1, Task 3).
- §"Schema change" → Task 2 (notes + version) + Tasks 7–8 (acceptableModes use) cover it.
- §"Get-RefinerRegressions change" → Task 3 implements the diff exactly as spec'd.
- §"Invoke-RefinerBaseline" signature, behaviour 1–7 → Task 9 implementation covers all 7 numbered behaviour items.
- §"Tests" → New `Describe` items 1 (schema), 2 (multi-acceptable), 3 (utility smoke) all mapped to Tasks 1, 3, 9.
- §"Risks" → Mitigations are in the plan: N=20 for baseline (Task 10), back-compat fallback in Get-RefinerRegressions (Task 3), `acceptableModes` admission criteria documented in Task 2's `notes` block.

**Placeholder scan:** No TBD/TODO. Every code step has full code. Every commit message is written out. The "eyeball the per-case hit rates" step in Task 10 names the exact thresholds to look for.

**Type / name consistency:**
- `Get-RefinerRegressions` signature: same in Task 3 step 3 (implementation) as in the existing function (`$BaselineCases`, `$FreshDistributions`, `$DropThreshold`).
- `Invoke-RefinerBaseline.ps1` parameters: `-Trials`, `-RefinerModel`, `-CorpusPath`, `-OutputPath`, `-Force` — consistent across Tasks 9 and 10.
- Case ids cross-referenced: every id in Tasks 5–8 appears only once (no collisions).
- Schema field names: `modeCounts`, `qCountCounts`, `latencyMsP50`, `latencyMsP95`, `samples`, `trialsPerCase`, `corpusVersion` consistent between Task 9 utility and Task 10 verification query.

Plan ready.
