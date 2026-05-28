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

    if ($latencies.Count -gt 0) {
        $sorted = @($latencies | Sort-Object)
        $p50Idx = [math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * 0.50))
        $p95Idx = [math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * 0.95))
        $p50 = [int]$sorted[$p50Idx]
        $p95 = [int]$sorted[$p95Idx]
    } else {
        $p50 = 0
        $p95 = 0
    }

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
