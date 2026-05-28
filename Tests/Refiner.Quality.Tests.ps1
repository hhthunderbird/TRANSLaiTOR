BeforeDiscovery {
    $here = $PSScriptRoot
    $repoRoot = Split-Path -Parent $here

    $corpusPath = Join-Path $here 'fixtures/refiner-corpus.json'
    $corpus = Get-Content $corpusPath -Raw | ConvertFrom-Json

    $refinerModel = if ($env:REFINER_MODEL) { $env:REFINER_MODEL } else { 'prompt-refiner' }
    $baselinePath = if ($env:REFINER_BASELINE) {
        $env:REFINER_BASELINE
    } else {
        Join-Path $repoRoot 'bench-results/baseline.json'
    }

    $ollamaCmd = $null
    try { $ollamaCmd = (Get-Command ollama -ErrorAction SilentlyContinue) } catch {}
    $modelPresent = $false
    if ($ollamaCmd) {
        $list = (& ollama list 2>$null | Out-String)
        $modelPresent = ($list -match [regex]::Escape($refinerModel))
    }
    $available = [bool]($ollamaCmd -and $modelPresent)
    $baselinePresent = Test-Path -LiteralPath $baselinePath

    $rejectedCases = @($corpus.cases | Where-Object { $_.expectedMode -eq 'rejected' })
    $liveCases     = @($corpus.cases | Where-Object { $_.expectedMode -ne 'rejected' })

    if ($available -and $baselinePresent) {
        $baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json
        $baselineLiveCases = @($baseline.cases | Where-Object { $_.expectedMode -ne 'rejected' })
    } else {
        $baselineLiveCases = @()
    }
}

BeforeAll {
    $here = $PSScriptRoot
    $repoRoot = Split-Path -Parent $here
    $module = Join-Path $repoRoot 'cprompt.psm1'
    Remove-Module cprompt -ErrorAction SilentlyContinue
    Import-Module $module -Force

    $script:Trials        = if ($env:REFINER_TRIALS)         { [int]$env:REFINER_TRIALS }            else { 10 }
    $script:RefinerModel  = if ($env:REFINER_MODEL)          { $env:REFINER_MODEL }                  else { 'prompt-refiner' }
    $script:BaselinePath  = if ($env:REFINER_BASELINE)       { $env:REFINER_BASELINE }               else { Join-Path $repoRoot 'bench-results/baseline.json' }
    $script:DropThreshold = if ($env:REFINER_DROP_THRESHOLD) { [double]$env:REFINER_DROP_THRESHOLD } else { 0.40 }

    function Invoke-Refiner {
        param([Parameter(Mandatory)][string]$Text)
        $raw = Invoke-OllamaModel -Text $Text -Model $script:RefinerModel
        if (-not $raw) { return $null }
        return Get-RefinerOutput $raw
    }

    function Get-ModeDistribution {
        param([Parameter(Mandatory)][string]$Text, [int]$N = $script:Trials)
        $results = @()
        for ($i = 0; $i -lt $N; $i++) {
            $parsed = Invoke-Refiner -Text $Text
            if ($null -eq $parsed) {
                $results += [pscustomobject]@{ Mode = 'invalid'; QCount = 0 }
            } else {
                $qc = 0
                if ($parsed.Mode -eq 'questions') { $qc = @($parsed.Payload).Count }
                $results += [pscustomobject]@{ Mode = $parsed.Mode; QCount = $qc }
            }
        }
        return $results
    }
}

Describe 'Refiner pre-gate (zero-signal)' {
    It "rejects zero-signal input: <_.id>" -ForEach $rejectedCases {
        (Test-InputIsZeroSignal -Text $_.input) | Should -Be $true
    }
}

Describe 'Refiner statistical invariants' -Tag 'Live' -Skip:(-not $available) {
    Context "case: <_.id>" -ForEach $liveCases {
        BeforeAll {
            $script:CaseId       = $_.id
            $script:ExpectedMode = $_.expectedMode
            $script:Dist         = Get-ModeDistribution -Text $_.input -N $script:Trials
        }

        It "produces parseable XML in >=80% of trials" {
            $valid = @($script:Dist | Where-Object { $_.Mode -ne 'invalid' }).Count
            $rate  = $valid / $script:Trials
            Write-Host ("    [{0}] valid={1}/{2} ({3:P0})" -f $script:CaseId, $valid, $script:Trials, $rate)
            ($rate -ge 0.8) | Should -Be $true
        }

        It 'never emits more than 1 question (cap invariant)' {
            $maxQ = ($script:Dist | Measure-Object -Property QCount -Maximum).Maximum
            if ($null -eq $maxQ) { $maxQ = 0 }
            ($maxQ -le 1) | Should -Be $true
        }

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
    }
}

Describe 'Refiner regression vs baseline' -Tag 'Live' -Skip:(-not ($available -and $baselinePresent)) {
    BeforeAll {
        $script:Baseline           = Get-Content $script:BaselinePath -Raw | ConvertFrom-Json
        $script:FreshDistributions = @{}
    }

    It "collects fresh distribution for case: <_.id>" -ForEach $baselineLiveCases {
        $script:FreshDistributions[$_.id] = Get-ModeDistribution -Text $_.input -N $script:Trials
        @($script:FreshDistributions[$_.id]).Count | Should -Be $script:Trials
    }

    It "fresh expected-mode rate stays within DropThreshold of baseline for every case" {
        $failures = @(Get-RefinerRegressions `
            -BaselineCases $script:Baseline.cases `
            -FreshDistributions $script:FreshDistributions `
            -DropThreshold $script:DropThreshold)

        foreach ($f in $failures) {
            Write-Host ("    REGRESSION [{0}] baseline={1:P0} fresh={2:P0} drop={3:P0} ({4})" -f `
                $f.id, $f.baselineRate, $f.freshRate, $f.drop, $f.reason) -ForegroundColor Red
        }
        $failures.Count | Should -Be 0
    }
}

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
        $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tests/Invoke-RefinerBaseline.ps1'

        & $scriptPath -Trials 2 -CorpusPath $miniCorpusPath -OutputPath $outPath -RefinerModel $script:RefinerModel -Force
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
