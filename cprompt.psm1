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
    Get-LastHistoryEntry
