<#
.SYNOPSIS
    Probe Modelfile.refiner output on every entry of eval-sample.json.
.DESCRIPTION
    For each raw input, call the prompt-refiner model directly (bypassing the
    compiler), parse the output via Get-RefinerOutput, and emit a JSONL row
    with raw, decision (passthrough/questions/parse-fail), payload, and
    refiner stats. Output is reviewer-friendly for spotting decision errors.
.EXAMPLE
    .\Tests\Invoke-RefinerProbe.ps1
    .\Tests\Invoke-RefinerProbe.ps1 -First 5
#>
[CmdletBinding()]
param(
    [int]$First = 0,
    [string]$RefinerModel = 'prompt-refiner',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'refiner-probe.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path $PSScriptRoot) 'cprompt.psm1') -Force

$samplePath = Join-Path $PSScriptRoot 'eval-sample.json'
$sample = Get-Content $samplePath -Encoding utf8 | ConvertFrom-Json
if ($First -gt 0) { $sample = $sample | Select-Object -First $First }

if (Test-Path $OutputPath) { Remove-Item $OutputPath }

$i = 0
$total = $sample.Count
foreach ($entry in $sample) {
    $i++
    $raw = $entry.raw
    if (-not $raw -or $raw.Length -lt 3) { continue }

    Write-Host "[$i/$total] $($raw.Substring(0, [Math]::Min($raw.Length, 60)))..." -ForegroundColor DarkGray

    $rawOut = ''
    $decision = 'invoke-error'
    $payload = ''
    $stats = $null
    try {
        $r = Invoke-OllamaModel -Text $raw -Model $RefinerModel -CaptureStats
        $rawOut = [string]$r.Text
        $stats = $r.Stats
        $parsed = Get-RefinerOutput $rawOut
        if ($null -eq $parsed) {
            $decision = 'parse-fail'
            $payload = $rawOut
        } else {
            $decision = $parsed.Mode
            $payload = if ($parsed.Mode -eq 'questions') { ($parsed.Payload -join ' || ') } else { [string]$parsed.Payload }
        }
    } catch {
        $payload = $_.Exception.Message
    }

    $record = [ordered]@{
        id        = $entry.id
        raw       = $raw
        rawLen    = $raw.Length
        decision  = $decision
        payload   = $payload
        rawOutput = $rawOut
    }
    if ($stats) { $record.stats = $stats }
    Add-Content -Path $OutputPath -Value (($record | ConvertTo-Json -Compress -Depth 6)) -Encoding utf8
}

Write-Host "`nDone. Output: $OutputPath" -ForegroundColor Green
