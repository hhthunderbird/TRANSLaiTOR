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

Export-ModuleMember -Function Remove-Bom, Get-PromptXml, Test-PromptXml, Resolve-Tool, Test-InputAcceptable
