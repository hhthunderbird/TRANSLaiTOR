Set-StrictMode -Version Latest

function Remove-Bom {
    [CmdletBinding()]
    param([string]$Text)
    if (-not $Text) { return '' }
    $bom = [char]0xFEFF
    if ($Text.Length -gt 0 -and $Text[0] -eq $bom) {
        return $Text.Substring(1)
    }
    return $Text
}

function Get-PromptXml {
    [CmdletBinding()]
    param([string]$RawOutput)
    if (-not $RawOutput) { return $null }
    $clean = Remove-Bom $RawOutput

    function _extractTag {
        param([string]$Src, [string]$Tag)
        # Capture content from <Tag> up to first of:
        #   - any closing tag  </word>   (handles hallucinated close-tag names)
        #   - lookahead at any open tag  <word>   (handles missing close + next section)
        #   - end of string  $          (handles missing close at EOF)
        $pattern = "(?s)<$Tag>(.*?)(?:</\w+>|(?=<\w+>)|`$)"
        $m = [regex]::Match($Src, $pattern)
        if (-not $m.Success) { return $null }
        return $m.Groups[1].Value.Trim()
    }

    $task        = _extractTag $clean 'task'
    $context     = _extractTag $clean 'context'
    $constraints = _extractTag $clean 'constraints'

    if (-not $task -or -not $context -or -not $constraints) { return $null }
    return "<task>$task</task><context>$context</context><constraints>$constraints</constraints>"
}

function Test-PromptXml {
    [CmdletBinding()]
    param([string]$Xml)
    if (-not $Xml) { return $false }
    $pattern = '(?s)<task>\s*(\S.*?)\s*</task>\s*<context>\s*(\S.*?)\s*</context>\s*<constraints>\s*(\S.*?)\s*</constraints>'
    return [regex]::IsMatch($Xml, $pattern)
}

function Resolve-Tool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Tool '$Name' not found in PATH."
    }
    return $cmd
}

function Get-CacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Text
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Model`0$Text")
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-CachedXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$CacheDir
    )
    $file = Join-Path $CacheDir "$Key.xml"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
}

function Set-CachedXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Xml,
        [Parameter(Mandatory)][string]$CacheDir
    )
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    $file = Join-Path $CacheDir "$Key.xml"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file, $Xml, $utf8NoBom)
}

function Add-HistoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entry
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $Entry.ContainsKey('ts')) {
        $Entry['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $line = ConvertTo-Json -InputObject $Entry -Compress -Depth 4
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-LastHistoryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return $null }
    return ($lines[-1] | ConvertFrom-Json)
}

function Add-MetricEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entry
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $Entry.ContainsKey('ts')) {
        $Entry['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $line = ConvertTo-Json -InputObject $Entry -Compress -Depth 6
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Read-MetricsFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $entries = @()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entries += ($line | ConvertFrom-Json)
        } catch {
            # Skip lines that fail to parse — partial writes, corruption, etc.
        }
    }
    return $entries
}

function Get-MetricsSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries
    )

    $hasField = {
        param($obj, $name)
        if ($obj -is [hashtable]) { return $obj.ContainsKey($name) }
        return $null -ne $obj.PSObject.Properties[$name]
    }

    $summary = [ordered]@{
        Count               = $Entries.Count
        CacheHitRate        = 0.0
        LatencyP50          = 0
        LatencyP95          = 0
        AvgCompressionRatio = 0.0
        ModeCounts          = @{}
    }

    if ($Entries.Count -eq 0) { return [pscustomobject]$summary }

    # Cache hit rate.
    $cacheHits = @($Entries | Where-Object {
        (& $hasField $_ 'mode') -and $_.mode -eq 'cache'
    }).Count
    $summary.CacheHitRate = [math]::Round($cacheHits / $Entries.Count, 4)

    # Mode counts.
    $modeCounts = @{}
    foreach ($e in $Entries) {
        $m = if (& $hasField $e 'mode') { [string]$e.mode } else { '' }
        if (-not $m) { $m = 'unknown' }
        if (-not $modeCounts.ContainsKey($m)) { $modeCounts[$m] = 0 }
        $modeCounts[$m] = $modeCounts[$m] + 1
    }
    $summary.ModeCounts = $modeCounts

    # Latency percentiles over totalMs.
    $latencies = @($Entries |
        Where-Object { & $hasField $_ 'totalMs' } |
        ForEach-Object { [int]$_.totalMs } |
        Sort-Object)
    if ($latencies.Count -gt 0) {
        $summary.LatencyP50 = $latencies[[math]::Max(0, [math]::Ceiling(0.50 * $latencies.Count) - 1)]
        $summary.LatencyP95 = $latencies[[math]::Max(0, [math]::Ceiling(0.95 * $latencies.Count) - 1)]
    }

    # Average compression ratio (xmlChars / inputChars) over entries with both > 0.
    $ratios = @($Entries |
        Where-Object {
            (& $hasField $_ 'inputChars') -and [int]$_.inputChars -gt 0 -and (& $hasField $_ 'xmlChars')
        } |
        ForEach-Object { [double]$_.xmlChars / [double]$_.inputChars })
    if ($ratios.Count -gt 0) {
        $sum = 0.0
        foreach ($r in $ratios) { $sum += $r }
        $summary.AvgCompressionRatio = [math]::Round($sum / $ratios.Count, 4)
    }

    return [pscustomobject]$summary
}

function Test-InputAcceptable {
    [CmdletBinding()]
    param(
        [string]$Text,
        [Parameter(Mandatory)][int]$MaxLength
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text.Length -gt $MaxLength) { return $false }
    return $true
}

function Get-RefinerOutput {
    [CmdletBinding()]
    param([string]$RawOutput)
    if (-not $RawOutput) { return $null }
    $clean = Remove-Bom $RawOutput

    $passthrough = [regex]::Match($clean, '(?s)<passthrough>(.*?)</\w+>')
    if ($passthrough.Success) {
        $payload = $passthrough.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($payload)) { return $null }
        return @{ Mode = 'passthrough'; Payload = $payload }
    }

    $questionsBlock = [regex]::Match($clean, '(?s)<questions>(.*?)</questions>')
    if (-not $questionsBlock.Success) {
        # Fallback: outer close tag hallucinated. Use greedy match to capture all
        # inner content up to the last </word> tag. Inner <q> parsing then handles
        # the rest defensively.
        $questionsBlock = [regex]::Match($clean, '(?s)<questions>(.*)</\w+>')
    }
    if ($questionsBlock.Success) {
        $inner = $questionsBlock.Groups[1].Value
        $qMatches = [regex]::Matches($inner, '(?s)<q>(.*?)</\w+>')
        $qs = @()
        foreach ($qm in $qMatches) {
            $text = $qm.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $qs += $text
            }
        }
        if ($qs.Count -eq 0) { return $null }
        if ($qs.Count -gt 3) { $qs = $qs[0..2] }
        return @{ Mode = 'questions'; Payload = $qs }
    }

    return $null
}

function Test-RefinerOutput {
    [CmdletBinding()]
    param($Parsed)
    if ($null -eq $Parsed) { return $false }
    if ($Parsed -isnot [hashtable]) { return $false }
    if (-not $Parsed.ContainsKey('Mode')) { return $false }
    if (-not $Parsed.ContainsKey('Payload')) { return $false }
    switch ($Parsed.Mode) {
        'passthrough' {
            return -not [string]::IsNullOrWhiteSpace([string]$Parsed.Payload)
        }
        'questions' {
            return ($Parsed.Payload -is [array]) -and ($Parsed.Payload.Count -gt 0)
        }
        default { return $false }
    }
}

function Merge-RefinementAnswers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Pairs
    )
    $kept = @()
    foreach ($pair in $Pairs) {
        $answer = [string]$pair.Answer
        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            $kept += "$($pair.Question): $($answer.Trim())"
        }
    }
    if ($kept.Count -eq 0) { return $Raw }
    return "$Raw`n`n" + ($kept -join "`n")
}

Export-ModuleMember -Function `
    Remove-Bom, `
    Get-PromptXml, `
    Test-PromptXml, `
    Resolve-Tool, `
    Test-InputAcceptable, `
    Get-CacheKey, `
    Get-CachedXml, `
    Set-CachedXml, `
    Add-HistoryEntry, `
    Get-LastHistoryEntry, `
    Add-MetricEntry, `
    Read-MetricsFile, `
    Get-MetricsSummary, `
    Get-RefinerOutput, `
    Test-RefinerOutput, `
    Merge-RefinementAnswers
