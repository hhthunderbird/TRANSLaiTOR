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

Export-ModuleMember -Function Test-PathContainsEntry
