Set-StrictMode -Version Latest

function Test-PathContainsEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathString,
        [Parameter(Mandatory)][string]$Entry
    )
    if ([string]::IsNullOrEmpty($PathString)) { return $false }
    $segments = $PathString -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    foreach ($s in $segments) {
        if ($s.Equals($Entry, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-PathEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathString,
        [Parameter(Mandatory)][string]$Entry
    )
    if ([string]::IsNullOrEmpty($PathString)) { return $Entry }
    if (Test-PathContainsEntry -PathString $PathString -Entry $Entry) {
        return $PathString
    }
    $trimmed = $PathString.TrimEnd(';')
    return "$trimmed;$Entry"
}

function Remove-PathEntry {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathString,
        [Parameter(Mandatory)][string]$Entry
    )
    if ([string]::IsNullOrEmpty($PathString)) { return '' }
    $kept = @()
    foreach ($s in ($PathString -split ';')) {
        $trim = $s.Trim()
        if (-not $trim) { continue }
        if (-not $trim.Equals($Entry, [System.StringComparison]::OrdinalIgnoreCase)) {
            $kept += $trim
        }
    }
    return ($kept -join ';')
}

Export-ModuleMember -Function Test-PathContainsEntry, Add-PathEntry, Remove-PathEntry
