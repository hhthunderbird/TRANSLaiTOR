[CmdletBinding()]
param(
    [int]$Trials = 10,
    [string]$RefinerModel = 'prompt-refiner',
    [string]$CorpusPath,
    [string]$OutputDir,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
# Keep Continue so ollama stderr (progress spinners) doesn't fault under PS 5.1
# native-command stderr wrapping. Errors we care about are surfaced via `throw`.
$ErrorActionPreference = 'Continue'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8NoBom
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'cprompt.psm1') -Force

if (-not $CorpusPath) {
    $CorpusPath = Join-Path $repoRoot 'Tests/fixtures/refiner-corpus.json'
}
if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot 'bench-results'
}

if (-not (Test-Path $CorpusPath)) {
    throw "Corpus not found: $CorpusPath"
}
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    throw "ollama not found on PATH"
}
$modelList = (& ollama list 2>$null | Out-String)
if ($modelList -notmatch [regex]::Escape($RefinerModel)) {
    throw "Refiner model '$RefinerModel' not installed. ollama list:`n$modelList"
}

$corpus = Get-Content $CorpusPath -Raw | ConvertFrom-Json

function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $sorted = $Values | Sort-Object
    $rank = [math]::Ceiling($P * $sorted.Count) - 1
    if ($rank -lt 0) { $rank = 0 }
    if ($rank -ge $sorted.Count) { $rank = $sorted.Count - 1 }
    return [double]$sorted[$rank]
}

$results = @()
$startedAt = Get-Date

foreach ($case in $corpus.cases) {
    Write-Host ("=== {0} (expected: {1})" -f $case.id, $case.expectedMode) -ForegroundColor Cyan

    if ($case.expectedMode -eq 'rejected') {
        $hit = Test-InputIsZeroSignal -Text $case.input
        $results += [pscustomobject]@{
            id            = $case.id
            input         = $case.input
            expectedMode  = $case.expectedMode
            preGateBlocks = [bool]$hit
            trials        = 0
            modeCounts    = @{ }
            qCountCounts  = @{ }
            latencyMsP50  = 0
            latencyMsP95  = 0
            samples       = @()
        }
        Write-Host ("    pre-gate blocks: {0}" -f $hit)
        continue
    }

    $modeCounts = @{ passthrough = 0; questions = 0; invalid = 0 }
    $qCountCounts = @{ }
    $latencies = @()
    $samples = @()

    for ($i = 0; $i -lt $Trials; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Invoke-OllamaModel -Text $case.input -Model $RefinerModel
        $sw.Stop()
        $latencies += [double]$sw.ElapsedMilliseconds

        $parsed = $null
        if ($raw) { $parsed = Get-RefinerOutput $raw }

        if ($null -eq $parsed) {
            $modeCounts['invalid']++
            if ($samples.Count -lt 2) {
                $samples += [pscustomobject]@{ mode = 'invalid'; raw = $raw.Trim() }
            }
            continue
        }

        $modeCounts[$parsed.Mode]++
        $qc = 0
        if ($parsed.Mode -eq 'questions') { $qc = @($parsed.Payload).Count }
        $key = [string]$qc
        if (-not $qCountCounts.ContainsKey($key)) { $qCountCounts[$key] = 0 }
        $qCountCounts[$key]++

        if ($samples.Count -lt 2) {
            $samples += [pscustomobject]@{
                mode    = $parsed.Mode
                qCount  = $qc
                payload = $parsed.Payload
            }
        }
    }

    $p50 = Get-Percentile -Values $latencies -P 0.5
    $p95 = Get-Percentile -Values $latencies -P 0.95

    $results += [pscustomobject]@{
        id            = $case.id
        input         = $case.input
        expectedMode  = $case.expectedMode
        preGateBlocks = $false
        trials        = $Trials
        modeCounts    = $modeCounts
        qCountCounts  = $qCountCounts
        latencyMsP50  = [math]::Round($p50)
        latencyMsP95  = [math]::Round($p95)
        samples       = $samples
    }

    foreach ($k in @('passthrough', 'questions', 'invalid')) {
        $v = $modeCounts[$k]
        $rate = if ($Trials -gt 0) { $v / $Trials } else { 0 }
        Write-Host ("    {0,-12} {1}/{2} ({3:P0})" -f $k, $v, $Trials, $rate)
    }
    Write-Host ("    latency p50={0}ms p95={1}ms" -f [math]::Round($p50), [math]::Round($p95))
}

$endedAt = Get-Date
$summary = [pscustomobject]@{
    startedAt    = $startedAt.ToString('o')
    endedAt      = $endedAt.ToString('o')
    durationSec  = [math]::Round(($endedAt - $startedAt).TotalSeconds, 2)
    refinerModel = $RefinerModel
    trialsPerCase = $Trials
    corpusVersion = $corpus.version
    cases        = $results
}

$json = $summary | ConvertTo-Json -Depth 8

if (-not $NoWrite) {
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }
    $stamp = $startedAt.ToString('yyyyMMdd-HHmmss')
    $outPath = Join-Path $OutputDir "bench-$stamp.json"
    [System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)
    Write-Host ""
    Write-Host "Wrote $outPath" -ForegroundColor Green
} else {
    Write-Output $json
}
