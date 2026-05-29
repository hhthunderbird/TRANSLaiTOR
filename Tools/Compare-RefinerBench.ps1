Set-StrictMode -Version Latest

# Compare-RefinerBench.ps1
#
# Offline analysis helper: compares a refiner-bench "candidate" run against a
# committed "baseline", per corpus case, and reports determinism + regressions.
#
# PURE data-in/data-out: no Ollama, no model calls, no network. Callers pass
# parsed objects (or file paths) and receive PSCustomObjects back.
#
# This file defines FUNCTIONS ONLY — there is zero top-level execution, so it is
# safe to dot-source from tests:  . $PSScriptRoot\..\Tools\Compare-RefinerBench.ps1


# --- internal helpers -------------------------------------------------------

# Read a count out of a modeCounts container that may be EITHER a [hashtable]
# (the bench tool emits a hashtable) OR a [PSCustomObject] (what ConvertFrom-Json
# produces). Returns 0 for any absent key. Strict-mode safe.
function Get-ModeCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ModeCounts,
        [Parameter(Mandatory)] [string] $Key
    )

    if ($null -eq $ModeCounts) { return 0 }

    if ($ModeCounts -is [hashtable]) {
        if ($ModeCounts.ContainsKey($Key)) {
            $v = $ModeCounts[$Key]
            if ($null -eq $v) { return 0 }
            return [int] $v
        }
        return 0
    }

    # PSCustomObject (or anything with PSObject.Properties)
    $prop = $ModeCounts.PSObject.Properties[$Key]
    if ($null -eq $prop -or $null -eq $prop.Value) { return 0 }
    return [int] $prop.Value
}

# Return the property value of a case object if the property exists, else $default.
# Strict-mode safe (does not throw on missing property).
function Get-CaseProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Case,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $Case) { return $Default }

    if ($Case -is [hashtable]) {
        if ($Case.ContainsKey($Name)) { return $Case[$Name] }
        return $Default
    }

    $prop = $Case.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

# The set of modes we measure determinism / dominance over.
$script:RefinerModes = @('passthrough', 'questions', 'invalid')


# --- per-case metric computation -------------------------------------------

# Compute the metrics for a single LIVE case (trials > 0). Returns $null for
# rejected / non-live cases (trials <= 0), which the caller SKIPS.
function Get-CaseMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Case
    )

    $trials = [int] (Get-CaseProperty -Case $Case -Name 'trials' -Default 0)
    if ($trials -le 0) { return $null }   # rejected / pre-gate cases are skipped

    $modeCounts = Get-CaseProperty -Case $Case -Name 'modeCounts' -Default $null

    $counts = [ordered]@{}
    foreach ($m in $script:RefinerModes) {
        $counts[$m] = Get-ModeCount -ModeCounts $modeCounts -Key $m
    }

    # maxModeShare = highest single mode count / trials (1.0 == fully deterministic)
    $maxCount = ($counts.Values | Measure-Object -Maximum).Maximum
    $maxModeShare = [double] $maxCount / $trials

    # dominantMode = mode with the highest count.
    # Tie-break (documented): prefer passthrough > questions > invalid when equal.
    # We iterate in that priority order and keep the first strict maximum.
    $dominantMode = $null
    $dominantCount = -1
    foreach ($m in $script:RefinerModes) {   # already in priority order
        if ($counts[$m] -gt $dominantCount) {
            $dominantCount = $counts[$m]
            $dominantMode = $m
        }
    }

    # expectedHit = sum of counts over the acceptable mode set / trials.
    # Acceptable set = acceptableModes if present AND non-empty, else [expectedMode].
    # Mirrors Get-RefinerRegressions in cprompt.psm1.
    $acceptable = Get-CaseProperty -Case $Case -Name 'acceptableModes' -Default $null
    $acceptableSet = @()
    if ($null -ne $acceptable -and @($acceptable).Count -gt 0) {
        $acceptableSet = @($acceptable)
    }
    else {
        $expectedMode = Get-CaseProperty -Case $Case -Name 'expectedMode' -Default $null
        if ($null -ne $expectedMode) { $acceptableSet = @($expectedMode) }
    }

    $hitCount = 0
    foreach ($m in $acceptableSet) {
        $hitCount += Get-ModeCount -ModeCounts $modeCounts -Key ([string] $m)
    }
    $expectedHit = [double] $hitCount / $trials

    return [PSCustomObject]@{
        maxModeShare = $maxModeShare
        dominantMode = $dominantMode
        expectedHit  = $expectedHit
    }
}


# --- loading ----------------------------------------------------------------

# Resolve either an explicit cases array or a path to a bench/baseline json file
# into an array of case objects. Tolerates BOM via ConvertFrom-Json.
function Resolve-BenchCases {
    [CmdletBinding()]
    param(
        [string]   $Path,
        [object[]] $Cases
    )

    if ($null -ne $Cases) { return $Cases }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Resolve-BenchCases: provide either -Path or -Cases."
    }

    $raw = Get-Content -Raw -Path $Path
    $obj = $raw | ConvertFrom-Json
    $casesProp = $obj.PSObject.Properties['cases']
    if ($null -eq $casesProp) { return @() }
    return @($casesProp.Value)
}


# --- main comparison --------------------------------------------------------

function Compare-RefinerBench {
    [CmdletBinding()]
    param(
        [string]   $BaselinePath,
        [object[]] $BaselineCases,
        [string]   $CandidatePath,
        [object[]] $CandidateCases,
        [double]   $DropThreshold = 0.40,
        [double]   $AbsoluteFloor = 0.60
    )

    $baseline  = Resolve-BenchCases -Path $BaselinePath  -Cases $BaselineCases
    $candidate = Resolve-BenchCases -Path $CandidatePath -Cases $CandidateCases

    # Build id -> metrics maps for LIVE cases only (rejected cases return $null).
    $baselineMetrics  = @{}
    $candidateMetrics = @{}

    foreach ($c in $baseline) {
        $id = Get-CaseProperty -Case $c -Name 'id' -Default $null
        if ($null -eq $id) { continue }
        $m = Get-CaseMetrics -Case $c
        if ($null -ne $m) { $baselineMetrics[[string] $id] = $m }
    }
    foreach ($c in $candidate) {
        $id = Get-CaseProperty -Case $c -Name 'id' -Default $null
        if ($null -eq $id) { continue }
        $m = Get-CaseMetrics -Case $c
        if ($null -ne $m) { $candidateMetrics[[string] $id] = $m }
    }

    # Union of live ids from either side, preserving baseline order then any
    # candidate-only ids in their order.
    $orderedIds = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($c in $baseline) {
        $id = [string] (Get-CaseProperty -Case $c -Name 'id' -Default $null)
        if ([string]::IsNullOrEmpty($id)) { continue }
        if (-not $baselineMetrics.ContainsKey($id)) { continue }
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $orderedIds.Add($id) }
    }
    foreach ($c in $candidate) {
        $id = [string] (Get-CaseProperty -Case $c -Name 'id' -Default $null)
        if ([string]::IsNullOrEmpty($id)) { continue }
        if (-not $candidateMetrics.ContainsKey($id)) { continue }
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $orderedIds.Add($id) }
    }

    $rows = foreach ($id in $orderedIds) {
        $b = if ($baselineMetrics.ContainsKey($id))  { $baselineMetrics[$id] }  else { $null }
        $c = if ($candidateMetrics.ContainsKey($id)) { $candidateMetrics[$id] } else { $null }

        $isRegression = $false
        $reason = ''

        if ($null -ne $b -and $null -eq $c) {
            # Present in baseline, gone from candidate.
            $isRegression = $true
            $reason = 'missing from candidate run'
        }
        elseif ($null -ne $b -and $null -ne $c) {
            $drop = $b.expectedHit - $c.expectedHit

            if ($c.expectedHit -lt ($b.expectedHit - $DropThreshold)) {
                $isRegression = $true
                $reason = ("drop {0:P0} exceeds threshold {1:P0}" -f $drop, $DropThreshold)
            }
            elseif (($b.expectedHit -ge $AbsoluteFloor) -and ($c.expectedHit -lt $AbsoluteFloor)) {
                $isRegression = $true
                $reason = ("fell below absolute floor {0:P0}" -f $AbsoluteFloor)
            }
        }
        # candidate-only (new) cases: never flagged as a regression.

        [PSCustomObject]@{
            id                    = $id
            baselineMaxShare      = if ($null -ne $b) { $b.maxModeShare } else { $null }
            candidateMaxShare     = if ($null -ne $c) { $c.maxModeShare } else { $null }
            baselineExpectedHit   = if ($null -ne $b) { $b.expectedHit }  else { $null }
            candidateExpectedHit  = if ($null -ne $c) { $c.expectedHit }  else { $null }
            dominantModeBaseline  = if ($null -ne $b) { $b.dominantMode } else { $null }
            dominantModeCandidate = if ($null -ne $c) { $c.dominantMode } else { $null }
            isRegression          = [bool] $isRegression
            regressionReason      = [string] $reason
        }
    }

    return @($rows)
}


# --- summary ----------------------------------------------------------------

function Get-RefinerBenchSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [AllowEmptyCollection()] [string[]] $BimodalIds = @()
    )

    $rows = @($Rows)

    $regressedRows = @($rows | Where-Object { $_.isRegression })
    $regressions   = @($regressedRows | ForEach-Object { $_.id })

    $watchedRows = @($rows | Where-Object { $BimodalIds -contains $_.id })

    $bimodalImproved = @(
        $watchedRows | Where-Object {
            $null -ne $_.candidateMaxShare -and
            $null -ne $_.baselineMaxShare -and
            $_.candidateMaxShare -gt $_.baselineMaxShare
        } | ForEach-Object {
            [PSCustomObject]@{
                id                = $_.id
                baselineMaxShare  = $_.baselineMaxShare
                candidateMaxShare = $_.candidateMaxShare
            }
        }
    )

    $isParetoWinner = ($regressedRows.Count -eq 0) -and ($bimodalImproved.Count -gt 0)

    return [PSCustomObject]@{
        regressionCount = $regressedRows.Count
        regressions     = $regressions
        bimodalImproved = $bimodalImproved
        bimodalWatched  = $watchedRows
        isParetoWinner  = [bool] $isParetoWinner
    }
}
