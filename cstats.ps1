[CmdletBinding()]
param(
    [int]$Last = 0,
    [string]$Path = (Join-Path $env:USERPROFILE '.cprompt/metrics.jsonl')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path $here 'cprompt.psm1'
Remove-Module cprompt -ErrorAction SilentlyContinue
Import-Module $module -Force

$entries = @(Read-MetricsFile -Path $Path)
if ($Last -gt 0 -and $entries.Count -gt $Last) {
    $entries = $entries[($entries.Count - $Last)..($entries.Count - 1)]
}

$summary = Get-MetricsSummary -Entries $entries

Write-Host "Metrics file : $Path"
Write-Host "Entries      : $($summary.Count)"
if ($summary.Count -eq 0) { return }

Write-Host ("Cache hits   : {0:P1}" -f $summary.CacheHitRate)
Write-Host ("p50 totalMs  : {0}" -f $summary.LatencyP50)
Write-Host ("p95 totalMs  : {0}" -f $summary.LatencyP95)
Write-Host ("Avg xml/input: {0:N2}" -f $summary.AvgCompressionRatio)
Write-Host ''
Write-Host 'Mode counts:'
foreach ($mode in ($summary.ModeCounts.Keys | Sort-Object)) {
    Write-Host ("  {0,-12} {1}" -f $mode, $summary.ModeCounts[$mode])
}
