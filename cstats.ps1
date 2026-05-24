[CmdletBinding()]
param(
    [int]$Last = 0,
    [string]$Since,
    [string]$By,
    [string]$Path = (Join-Path $env:USERPROFILE '.cprompt/metrics.jsonl')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path $here 'cprompt.psm1'
Remove-Module cprompt -ErrorAction SilentlyContinue
Import-Module $module -Force

function Write-MetricsSummary {
    param($summary)
    Write-Host ("Cache hits   : {0:P1}" -f $summary.CacheHitRate)
    Write-Host ("p50 totalMs  : {0}" -f $summary.LatencyP50)
    Write-Host ("p95 totalMs  : {0}" -f $summary.LatencyP95)
    Write-Host ("Avg xml/input: {0:N2}" -f $summary.AvgCompressionRatio)
    if ($summary.CompilerEvalCountMedian -gt 0) {
        Write-Host ("Compiler eval/s p50: {0:N2}" -f $summary.CompilerEvalRateP50)
        Write-Host ("Compiler eval/s p95: {0:N2}" -f $summary.CompilerEvalRateP95)
        Write-Host ("Compiler tokens out (median): {0}" -f $summary.CompilerEvalCountMedian)
    }
    if ($summary.ColdStartCount -gt 0) {
        Write-Host ("Cold starts      : {0}/{1} ({2:P1})" -f $summary.ColdStartCount, $summary.Count, $summary.ColdStartRate)
    }
    if ($summary.ClaudeSendCount -gt 0) {
        Write-Host ("Claude sends     : {0}" -f $summary.ClaudeSendCount)
        Write-Host ("Claude cost total: `${0:N2}" -f $summary.ClaudeCostTotal)
        Write-Host ("Claude cost avg  : `${0:N2}" -f $summary.ClaudeCostAvg)
        Write-Host ("Claude tokens avg: {0} out / {1} in" -f $summary.ClaudeAvgOutputTokens, $summary.ClaudeAvgInputTokens)
    }
    Write-Host ''
    Write-Host 'Mode counts:'
    foreach ($m in ($summary.ModeCounts.Keys | Sort-Object)) {
        Write-Host ("  {0,-12} {1}" -f $m, $summary.ModeCounts[$m])
    }
}

# --- load and filter entries ---
$entries = @(Read-MetricsFile -Path $Path)

if ($Since) {
    $sinceDate = ConvertTo-SinceDate $Since -ErrorAction SilentlyContinue
    if ($null -eq $sinceDate) {
        Write-Host "ERRO: Invalid -Since value '$Since'. Use relative (7d, 24h, 1w) or ISO-8601 (2026-05-01)." -ForegroundColor Red
        exit 1
    }
    $entries = @($entries | Where-Object { [datetime]$_.ts -ge $sinceDate })
}

if ($Last -gt 0 -and $entries.Count -gt $Last) {
    $entries = $entries[($entries.Count - $Last)..($entries.Count - 1)]
}

Write-Host "Metrics file : $Path"
Write-Host "Entries      : $($entries.Count)"
if ($entries.Count -eq 0) { return }

# --- display ---
if ($By) {
    if ($By -notin @('mode','model')) {
        Write-Host "ERRO: Invalid -By value '$By'. Use 'mode' or 'model'." -ForegroundColor Red
        exit 1
    }
    $hasField = {
        param($obj, $name)
        if ($obj -is [hashtable]) { return $obj.ContainsKey($name) }
        return $null -ne $obj.PSObject.Properties[$name]
    }
    $groups = [ordered]@{}
    foreach ($e in $entries) {
        $key = if (& $hasField $e $By) { [string]$e.$By } else { '(unknown)' }
        if (-not $key) { $key = '(unknown)' }
        if (-not $groups.Contains($key)) { $groups[$key] = [System.Collections.ArrayList]@() }
        [void]$groups[$key].Add($e)
    }
    foreach ($key in ($groups.Keys | Sort-Object { $groups[$_].Count } -Descending)) {
        $groupEntries = @($groups[$key])
        Write-Host ''
        Write-Host "=== ${By}: $key ($($groupEntries.Count) entries) ==="
        $s = Get-MetricsSummary -Entries $groupEntries
        Write-MetricsSummary $s
    }
} else {
    $summary = Get-MetricsSummary -Entries $entries
    Write-MetricsSummary $summary
}
