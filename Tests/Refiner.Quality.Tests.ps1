$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$module = Join-Path $repoRoot 'cprompt.psm1'
Remove-Module cprompt -ErrorAction SilentlyContinue
Import-Module $module -Force

$corpusPath = Join-Path $here 'fixtures/refiner-corpus.json'
$corpus = Get-Content $corpusPath -Raw | ConvertFrom-Json

$script:Trials = if ($env:REFINER_TRIALS) { [int]$env:REFINER_TRIALS } else { 10 }
$script:RefinerModel = if ($env:REFINER_MODEL) { $env:REFINER_MODEL } else { 'prompt-refiner' }

# Probe environment once. Pester 3.x has no native -Skip; we gate via $script:Available
$script:OllamaCmd = $null
try { $script:OllamaCmd = (Get-Command ollama -ErrorAction SilentlyContinue) } catch {}
$script:ModelPresent = $false
if ($script:OllamaCmd) {
    $list = (& ollama list 2>$null | Out-String)
    $script:ModelPresent = ($list -match [regex]::Escape($script:RefinerModel))
}
$script:Available = [bool]($script:OllamaCmd -and $script:ModelPresent)

function Invoke-Refiner {
    param([Parameter(Mandatory)][string]$Text)
    $raw = ($Text | & ollama run --nowordwrap $script:RefinerModel 2>$null | Out-String)
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

Describe 'Refiner pre-gate (zero-signal)' {
    foreach ($case in $corpus.cases) {
        if ($case.expectedMode -ne 'rejected') { continue }
        $localCase = $case
        It "rejects zero-signal input: $($localCase.id)" {
            (Test-InputIsZeroSignal -Text $localCase.input) | Should Be $true
        }
    }
}

Describe 'Refiner statistical invariants' -Tags 'Live' {
    if (-not $script:Available) {
        It 'skipped: ollama or prompt-refiner model not found' {
            Write-Warning "Skipping live refiner tests: ollama=$([bool]$script:OllamaCmd) model=$script:ModelPresent"
            $true | Should Be $true
        }
        return
    }

    foreach ($case in $corpus.cases) {
        if ($case.expectedMode -eq 'rejected') { continue }
        $localCase = $case
        Context "case: $($localCase.id)" {
            $script:Dist = $null
            It "produces parseable XML in >=80% of $script:Trials trials" {
                $script:Dist = Get-ModeDistribution -Text $localCase.input -N $script:Trials
                $valid = @($script:Dist | Where-Object { $_.Mode -ne 'invalid' }).Count
                $rate = $valid / $script:Trials
                Write-Host ("    [{0}] valid={1}/{2} ({3:P0})" -f $localCase.id, $valid, $script:Trials, $rate)
                ($rate -ge 0.8) | Should Be $true
            }

            It 'never emits more than 1 question (cap invariant)' {
                $maxQ = ($script:Dist | Measure-Object -Property QCount -Maximum).Maximum
                if ($null -eq $maxQ) { $maxQ = 0 }
                ($maxQ -le 1) | Should Be $true
            }

            if ($localCase.expectedMode -eq 'passthrough') {
                It 'hits passthrough mode in >=60% of trials' {
                    $pt = @($script:Dist | Where-Object { $_.Mode -eq 'passthrough' }).Count
                    $rate = $pt / $script:Trials
                    Write-Host ("    [{0}] passthrough={1}/{2} ({3:P0})" -f $localCase.id, $pt, $script:Trials, $rate)
                    ($rate -ge 0.6) | Should Be $true
                }
            }
            elseif ($localCase.expectedMode -eq 'questions') {
                It 'hits questions mode in >=60% of trials' {
                    $q = @($script:Dist | Where-Object { $_.Mode -eq 'questions' }).Count
                    $rate = $q / $script:Trials
                    Write-Host ("    [{0}] questions={1}/{2} ({3:P0})" -f $localCase.id, $q, $script:Trials, $rate)
                    ($rate -ge 0.6) | Should Be $true
                }
            }
        }
    }
}
