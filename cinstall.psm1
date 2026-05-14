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

function Test-PathExtShouldRemove {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PathExtString,
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$StampPath
    )
    if (-not (Test-Path -LiteralPath $StampPath)) { return $false }
    return [bool](Test-PathContainsEntry -PathString $PathExtString -Entry $Entry)
}

function Get-InstallRecoveryHint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason,
        [Parameter(Mandatory)][string]$InstallDir
    )
    return @"
ERRO: $Reason (codigo $Code)
estado parcial: runtime files podem ter sido copiados para $InstallDir.
recuperacao:
  1. corrija a causa raiz e rode install.ps1 de novo (operacao e idempotente)
  2. ou rode uninstall.ps1 -PurgeInstall para limpar tudo
"@
}

Export-ModuleMember -Function Test-PathContainsEntry, Add-PathEntry, Remove-PathEntry, Get-InstallRecoveryHint, Test-PathExtShouldRemove
