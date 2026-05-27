<#
.SYNOPSIS
    Re-runs eval sample through c.ps1 and captures fresh XML for comparison.
.DESCRIPTION
    Reads Tests/eval-sample.json, pipes each rawInput through c.ps1 -Raw -NoRefine,
    and writes a JSONL file with original + fresh XML side by side.
.EXAMPLE
    .\Tests\Invoke-EvalRerun.ps1
    .\Tests\Invoke-EvalRerun.ps1 -First 3   # smoke test on first 3 entries
#>
[CmdletBinding()]
param(
    [int]$First = 0,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'eval-rerun.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$samplePath = Join-Path $PSScriptRoot 'eval-sample.json'
if (-not (Test-Path $samplePath)) {
    Write-Error "eval-sample.json not found at $samplePath"
    return
}

$sample = Get-Content $samplePath -Encoding utf8 | ConvertFrom-Json
if ($First -gt 0) { $sample = $sample | Select-Object -First $First }

$scriptPath = Join-Path (Split-Path $PSScriptRoot) 'c.ps1'
$total = $sample.Count
$i = 0

if (Test-Path $OutputPath) { Remove-Item $OutputPath }

foreach ($entry in $sample) {
    $i++
    $raw = $entry.raw
    if (-not $raw -or $raw.Length -lt 3) { continue }

    $pct = [math]::Round(($i / $total) * 100)
    Write-Progress -Activity "Eval rerun" -Status "$i/$total ($pct%)" -PercentComplete $pct

    try {
        $result = & $scriptPath -Raw -NoRefine -NoCache $raw 2>&1
        $xmlLine = ($result | Where-Object { $_ -is [string] -and $_ -match '<task>' }) -join ''
        if (-not $xmlLine) { $xmlLine = ($result | Out-String).Trim() }
    } catch {
        $xmlLine = "ERROR: $($_.Exception.Message)"
    }

    $record = @{
        id       = $entry.id
        raw      = $raw
        old_xml  = $entry.xml
        new_xml  = $xmlLine
    } | ConvertTo-Json -Compress

    Add-Content -Path $OutputPath -Value $record -Encoding utf8
    Write-Host "[$i/$total] $($raw.Substring(0, [Math]::Min($raw.Length, 50)))..." -ForegroundColor DarkGray
}

Write-Progress -Activity "Eval rerun" -Completed
Write-Host "`nDone. Output: $OutputPath" -ForegroundColor Green
Write-Host "Compare old_xml vs new_xml to measure change impact." -ForegroundColor Cyan
