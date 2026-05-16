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
            $hit  = @($script:Dist | Where-Object { $_.Mode -eq $script:ExpectedMode }).Count
            $rate = $hit / $script:Trials
            Write-Host ("    [{0}] {1}={2}/{3} ({4:P0})" -f $script:CaseId, $script:ExpectedMode, $hit, $script:Trials, $rate)
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
