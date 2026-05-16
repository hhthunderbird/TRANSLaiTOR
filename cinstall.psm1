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

function Resolve-UserPathExtForInstall {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$UserPathExt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MachinePathExt,
        [Parameter(Mandatory)][string]$Entry
    )
    # User PATHEXT is a full override of Machine PATHEXT (not merged like
    # PATH). Writing just '.PS1' would drop .EXE/.CMD/etc from the user
    # process scope. When User is empty we seed from Machine first so the
    # resulting User PATHEXT is a superset, not a replacement.
    $previous = if ($null -eq $UserPathExt) { '' } else { $UserPathExt }

    if ([string]::IsNullOrEmpty($previous)) {
        $base = $MachinePathExt.TrimEnd(';')
        if ([string]::IsNullOrEmpty($base)) {
            $newValue = $Entry
        } else {
            $newValue = "$base;$Entry"
        }
        return [pscustomobject]@{
            Value         = $newValue
            Seeded        = $true
            PreviousValue = $previous
            Changed       = $true
        }
    }

    $newValue = Add-PathEntry -PathString $previous -Entry $Entry
    return [pscustomobject]@{
        Value         = $newValue
        Seeded        = $false
        PreviousValue = $previous
        Changed       = ($newValue -ne $previous)
    }
}

function New-PathExtStamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PreviousValue,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WrittenValue,
        [Parameter(Mandatory)][bool]$Seeded
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload = [ordered]@{
        ts            = (Get-Date -Format 'o')
        addedEntry    = $Entry
        seeded        = $Seeded
        previousValue = $PreviousValue
        writtenValue  = $WrittenValue
    } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $Path -Value $payload -Encoding UTF8
}

function Read-PathExtStamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Format        = 'missing'
            Entry         = '.PS1'
            Seeded        = $false
            PreviousValue = ''
            WrittenValue  = ''
        }
    }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { $raw = '' }
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        # Must look like a stamp, not just any JSON. Tolerate missing fields.
        $entry         = if ($obj.PSObject.Properties.Match('addedEntry').Count)    { [string]$obj.addedEntry }    else { '.PS1' }
        $seeded        = if ($obj.PSObject.Properties.Match('seeded').Count)        { [bool]$obj.seeded }          else { $false }
        $previousValue = if ($obj.PSObject.Properties.Match('previousValue').Count) { [string]$obj.previousValue } else { '' }
        $writtenValue  = if ($obj.PSObject.Properties.Match('writtenValue').Count)  { [string]$obj.writtenValue }  else { '' }
        return [pscustomobject]@{
            Format        = 'json'
            Entry         = $entry
            Seeded        = $seeded
            PreviousValue = $previousValue
            WrittenValue  = $writtenValue
        }
    } catch {
        return [pscustomobject]@{
            Format        = 'legacy'
            Entry         = '.PS1'
            Seeded        = $false
            PreviousValue = ''
            WrittenValue  = ''
        }
    }
}

function Resolve-UserPathExtForUninstall {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$CurrentUserPathExt,
        [Parameter(Mandatory)][psobject]$Stamp
    )
    if ($Stamp.Format -eq 'missing') {
        return [pscustomobject]@{ Action = 'no-op'; Value = $CurrentUserPathExt }
    }
    $entry = if ($Stamp.Entry) { $Stamp.Entry } else { '.PS1' }
    if ($Stamp.Format -eq 'json' -and $Stamp.Seeded) {
        # Compare current against what we wrote at install time. If they
        # match exactly, the user has not edited PATHEXT since — restore
        # to the previous value (typically empty, letting Machine take
        # over again). If they diverged, fall back to surgical removal
        # so we do not nuke their additions.
        $current  = if ($null -eq $CurrentUserPathExt) { '' } else { $CurrentUserPathExt }
        if ($current.Equals([string]$Stamp.WrittenValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Action = 'restore-previous'
                Value  = [string]$Stamp.PreviousValue
            }
        }
    }
    if (-not (Test-PathContainsEntry -PathString $CurrentUserPathExt -Entry $entry)) {
        return [pscustomobject]@{ Action = 'no-op'; Value = $CurrentUserPathExt }
    }
    return [pscustomobject]@{
        Action = 'remove-entry'
        Value  = (Remove-PathEntry -PathString $CurrentUserPathExt -Entry $entry)
    }
}

Export-ModuleMember -Function Test-PathContainsEntry, Add-PathEntry, Remove-PathEntry, Get-InstallRecoveryHint, Test-PathExtShouldRemove, Resolve-UserPathExtForInstall, New-PathExtStamp, Read-PathExtStamp, Resolve-UserPathExtForUninstall
