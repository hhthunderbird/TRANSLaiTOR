$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path (Split-Path -Parent $here) 'cinstall.psm1'
Remove-Module cinstall -ErrorAction SilentlyContinue
Import-Module $module -Force

Describe 'Test-PathContainsEntry' {
    It 'returns $true when the entry appears verbatim' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B;C:\C' -Entry 'C:\B' | Should -Be $true
    }

    It 'returns $false when the entry is absent' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should -Be $false
    }

    It 'matches case-insensitively' {
        Test-PathContainsEntry -PathString 'C:\Users\HHTHU\Scripts' -Entry 'c:\users\hhthu\scripts' | Should -Be $true
    }

    It 'tolerates a trailing semicolon in the PathString' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B;' -Entry 'C:\B' | Should -Be $true
    }

    It 'matches a whole segment, not a substring' {
        # "C:\B" must NOT match inside "C:\Bin".
        Test-PathContainsEntry -PathString 'C:\A;C:\Bin' -Entry 'C:\B' | Should -Be $false
    }

    It 'returns $false on an empty PathString' {
        Test-PathContainsEntry -PathString '' -Entry 'C:\A' | Should -Be $false
    }

    It 'treats a null PathString as empty' {
        Test-PathContainsEntry -PathString $null -Entry 'C:\A' | Should -Be $false
    }
}

Describe 'Add-PathEntry' {
    It 'appends to a non-empty PathString with a separating semicolon' {
        Add-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should -Be 'C:\A;C:\B;C:\C'
    }

    It 'returns just the entry when PathString is empty' {
        Add-PathEntry -PathString '' -Entry 'C:\A' | Should -Be 'C:\A'
    }

    It 'returns just the entry when PathString is null' {
        Add-PathEntry -PathString $null -Entry 'C:\A' | Should -Be 'C:\A'
    }

    It 'returns the PathString unchanged when the entry is already present' {
        Add-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\B' | Should -Be 'C:\A;C:\B'
    }

    It 'is case-insensitive when checking for existing presence' {
        Add-PathEntry -PathString 'C:\users\HHTHU\Scripts' -Entry 'C:\Users\hhthu\scripts' | Should -Be 'C:\users\HHTHU\Scripts'
    }

    It 'strips a single trailing semicolon before appending' {
        Add-PathEntry -PathString 'C:\A;C:\B;' -Entry 'C:\C' | Should -Be 'C:\A;C:\B;C:\C'
    }
}

Describe 'Remove-PathEntry' {
    It 'removes a middle entry and rejoins with semicolons' {
        Remove-PathEntry -PathString 'C:\A;C:\B;C:\C' -Entry 'C:\B' | Should -Be 'C:\A;C:\C'
    }

    It 'removes a leading entry' {
        Remove-PathEntry -PathString 'C:\B;C:\A' -Entry 'C:\B' | Should -Be 'C:\A'
    }

    It 'removes a trailing entry' {
        Remove-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\B' | Should -Be 'C:\A'
    }

    It 'returns the PathString unchanged when the entry is absent' {
        Remove-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should -Be 'C:\A;C:\B'
    }

    It 'matches case-insensitively when removing' {
        Remove-PathEntry -PathString 'C:\A;C:\Users\hhthu\Scripts;C:\C' -Entry 'c:\users\hhthu\scripts' |
            Should -Be 'C:\A;C:\C'
    }

    It 'removes all duplicate occurrences' {
        Remove-PathEntry -PathString 'C:\A;C:\B;C:\B;C:\C' -Entry 'C:\B' | Should -Be 'C:\A;C:\C'
    }

    It 'returns an empty string when only the entry was present' {
        Remove-PathEntry -PathString 'C:\B' -Entry 'C:\B' | Should -Be ''
    }

    It 'returns an empty string when PathString is null' {
        Remove-PathEntry -PathString $null -Entry 'C:\B' | Should -Be ''
    }

    It 'preserves a non-matching segment that contains the entry as a substring' {
        # "C:\B" must NOT remove "C:\Bin".
        Remove-PathEntry -PathString 'C:\Bin;C:\B' -Entry 'C:\B' | Should -Be 'C:\Bin'
    }
}

Describe 'Test-PathExtShouldRemove' {
    BeforeEach {
        $script:tmpStamp = Join-Path $env:TEMP ("pathext-stamp-{0}.tmp" -f [guid]::NewGuid())
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:tmpStamp) {
            Remove-Item -LiteralPath $script:tmpStamp -Force
        }
    }

    It 'returns $false when the stamp file does not exist (we did not add the entry)' {
        Test-PathExtShouldRemove -PathExtString '.COM;.EXE;.PS1' -Entry '.PS1' -StampPath $script:tmpStamp | Should -Be $false
    }

    It 'returns $false when the stamp exists but the entry is absent (idempotent no-op)' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString '.COM;.EXE' -Entry '.PS1' -StampPath $script:tmpStamp | Should -Be $false
    }

    It 'returns $true when the stamp exists and the entry is present' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString '.COM;.EXE;.PS1' -Entry '.PS1' -StampPath $script:tmpStamp | Should -Be $true
    }

    It 'matches the entry case-insensitively' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString '.COM;.exe;.ps1' -Entry '.PS1' -StampPath $script:tmpStamp | Should -Be $true
    }

    It 'returns $false on a null PathExtString even with stamp present' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString $null -Entry '.PS1' -StampPath $script:tmpStamp | Should -Be $false
    }
}

Describe 'Get-InstallRecoveryHint' {
    It 'embeds the reason and exit code in the header' {
        $hint = Get-InstallRecoveryHint -Code 4 -Reason 'ollama create falhou' -InstallDir 'C:\X'
        $hint | Should -Match 'ollama create falhou'
        $hint | Should -Match 'codigo 4'
    }

    It 'mentions the install directory so the user knows where partial state lives' {
        $hint = Get-InstallRecoveryHint -Code 2 -Reason 'ollama nao encontrado' -InstallDir 'C:\Users\me\Scripts'
        $hint | Should -Match 'C:\\Users\\me\\Scripts'
    }

    It 'suggests re-running install.ps1 as the primary recovery path' {
        $hint = Get-InstallRecoveryHint -Code 5 -Reason 'pull failed' -InstallDir 'C:\X'
        $hint | Should -Match 'install\.ps1'
    }

    It 'suggests uninstall.ps1 -PurgeInstall as the cleanup fallback' {
        $hint = Get-InstallRecoveryHint -Code 5 -Reason 'pull failed' -InstallDir 'C:\X'
        $hint | Should -Match 'uninstall\.ps1'
        $hint | Should -Match 'PurgeInstall'
    }

    It 'tolerates an empty reason without throwing' {
        { Get-InstallRecoveryHint -Code 1 -Reason '' -InstallDir 'C:\X' } | Should -Not -Throw
    }
}

Describe 'Resolve-UserPathExtForInstall' {
    # The bug we are guarding against: install.ps1 used to feed an empty
    # User PATHEXT into Add-PathEntry, which returned just '.PS1'. Windows
    # treats User PATHEXT as a full override of Machine PATHEXT (it is NOT
    # merged like PATH). That made `.EXE` fall out of the process PATHEXT
    # of any subsequently-launched user shell and broke Get-Command for
    # every .exe binary in the user scope.

    BeforeAll {
        $script:machineExt = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
    }

    It 'seeds from Machine PATHEXT when User PATHEXT is empty, then appends the entry' {
        $r = Resolve-UserPathExtForInstall -UserPathExt '' -MachinePathExt $script:machineExt -Entry '.PS1'
        $r.Changed       | Should -Be $true
        $r.Seeded        | Should -Be $true
        $r.PreviousValue | Should -Be ''
        $r.Value         | Should -Be "$($script:machineExt);.PS1"
    }

    It 'treats a null User PATHEXT identically to empty (seeds + appends)' {
        $r = Resolve-UserPathExtForInstall -UserPathExt $null -MachinePathExt $script:machineExt -Entry '.PS1'
        $r.Seeded | Should -Be $true
        $r.Value  | Should -Be "$($script:machineExt);.PS1"
    }

    It 'appends the entry to a non-empty User PATHEXT without seeding from Machine' {
        $r = Resolve-UserPathExtForInstall -UserPathExt '.CUSTOM' -MachinePathExt $script:machineExt -Entry '.PS1'
        $r.Changed       | Should -Be $true
        $r.Seeded        | Should -Be $false
        $r.PreviousValue | Should -Be '.CUSTOM'
        $r.Value         | Should -Be '.CUSTOM;.PS1'
    }

    It 'returns Changed=$false when the entry is already present in a non-empty User PATHEXT (idempotent)' {
        $r = Resolve-UserPathExtForInstall -UserPathExt '.CUSTOM;.PS1' -MachinePathExt $script:machineExt -Entry '.PS1'
        $r.Changed       | Should -Be $false
        $r.Seeded        | Should -Be $false
        $r.PreviousValue | Should -Be '.CUSTOM;.PS1'
        $r.Value         | Should -Be '.CUSTOM;.PS1'
    }

    It 'returns Changed=$false when the seeded value would equal current (re-run after seeded install is a no-op)' {
        # Simulate: install seeded once, then user re-runs install.
        $seeded = "$($script:machineExt);.PS1"
        $r = Resolve-UserPathExtForInstall -UserPathExt $seeded -MachinePathExt $script:machineExt -Entry '.PS1'
        $r.Changed | Should -Be $false
        $r.Seeded  | Should -Be $false  # current is non-empty, no seeding needed
        $r.Value   | Should -Be $seeded
    }

    It 'is case-insensitive on the entry presence check' {
        $r = Resolve-UserPathExtForInstall -UserPathExt '.custom;.ps1' -MachinePathExt $script:machineExt -Entry '.PS1'
        $r.Changed | Should -Be $false
    }
}

Describe 'Read-PathExtStamp' {
    BeforeEach {
        $script:stamp = Join-Path $env:TEMP ("pathext-stamp-{0}.tmp" -f [guid]::NewGuid())
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:stamp) {
            Remove-Item -LiteralPath $script:stamp -Force
        }
    }

    It "returns Format='missing' when the stamp file does not exist" {
        $r = Read-PathExtStamp -Path $script:stamp
        $r.Format | Should -Be 'missing'
    }

    It "returns Format='legacy' for a plain-text timestamp stamp (pre-fix installs)" {
        # Legacy stamps were just a timestamp written by Set-Content.
        Set-Content -LiteralPath $script:stamp -Value (Get-Date -Format 'o') -Encoding UTF8
        $r = Read-PathExtStamp -Path $script:stamp
        $r.Format        | Should -Be 'legacy'
        $r.Seeded        | Should -Be $false
        $r.Entry         | Should -Be '.PS1'
        $r.PreviousValue | Should -Be ''
        $r.WrittenValue  | Should -Be ''
    }

    It "returns Format='json' for a structured stamp written by the new installer" {
        $payload = [ordered]@{
            ts            = '2026-05-15T22:00:00Z'
            addedEntry    = '.PS1'
            seeded        = $true
            previousValue = ''
            writtenValue  = '.COM;.EXE;.PS1'
        } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $script:stamp -Value $payload -Encoding UTF8
        $r = Read-PathExtStamp -Path $script:stamp
        $r.Format        | Should -Be 'json'
        $r.Seeded        | Should -Be $true
        $r.Entry         | Should -Be '.PS1'
        $r.PreviousValue | Should -Be ''
        $r.WrittenValue  | Should -Be '.COM;.EXE;.PS1'
    }

    It "falls back to Format='legacy' when the file exists but is not valid JSON" {
        Set-Content -LiteralPath $script:stamp -Value 'not json {{{' -Encoding UTF8
        $r = Read-PathExtStamp -Path $script:stamp
        $r.Format | Should -Be 'legacy'
        $r.Seeded | Should -Be $false
    }
}

Describe 'Resolve-UserPathExtForUninstall' {
    BeforeAll {
        $script:stampMissing = [pscustomobject]@{ Format = 'missing'; Seeded = $false; Entry = '.PS1'; PreviousValue = ''; WrittenValue = '' }
        $script:stampLegacy  = [pscustomobject]@{ Format = 'legacy';  Seeded = $false; Entry = '.PS1'; PreviousValue = ''; WrittenValue = '' }
    }

    It "returns Action='no-op' when the stamp is missing (we did not add the entry)" {
        $r = Resolve-UserPathExtForUninstall -CurrentUserPathExt '.COM;.EXE;.PS1' -Stamp $script:stampMissing
        $r.Action | Should -Be 'no-op'
    }

    It "legacy stamp + entry present: Action='remove-entry', removes only the entry" {
        $r = Resolve-UserPathExtForUninstall -CurrentUserPathExt '.COM;.EXE;.PS1' -Stamp $script:stampLegacy
        $r.Action | Should -Be 'remove-entry'
        $r.Value  | Should -Be '.COM;.EXE'
    }

    It "legacy stamp + entry absent: Action='no-op' (idempotent)" {
        $r = Resolve-UserPathExtForUninstall -CurrentUserPathExt '.COM;.EXE' -Stamp $script:stampLegacy
        $r.Action | Should -Be 'no-op'
    }

    It "json stamp + Seeded=true + current matches writtenValue: Action='restore-previous', returns previousValue" {
        $stamp = [pscustomobject]@{
            Format = 'json'; Seeded = $true; Entry = '.PS1'
            PreviousValue = ''; WrittenValue = '.COM;.EXE;.PS1'
        }
        $r = Resolve-UserPathExtForUninstall -CurrentUserPathExt '.COM;.EXE;.PS1' -Stamp $stamp
        $r.Action | Should -Be 'restore-previous'
        $r.Value  | Should -Be ''
    }

    It "json stamp + Seeded=true + user diverged from writtenValue: Action='remove-entry' (preserve user edits)" {
        $stamp = [pscustomobject]@{
            Format = 'json'; Seeded = $true; Entry = '.PS1'
            PreviousValue = ''; WrittenValue = '.COM;.EXE;.PS1'
        }
        # User added .MYEXT after install. We must NOT nuke that.
        $r = Resolve-UserPathExtForUninstall -CurrentUserPathExt '.COM;.EXE;.PS1;.MYEXT' -Stamp $stamp
        $r.Action | Should -Be 'remove-entry'
        $r.Value  | Should -Be '.COM;.EXE;.MYEXT'
    }

    It "json stamp + Seeded=false (append-only install): Action='remove-entry'" {
        $stamp = [pscustomobject]@{
            Format = 'json'; Seeded = $false; Entry = '.PS1'
            PreviousValue = '.CUSTOM'; WrittenValue = '.CUSTOM;.PS1'
        }
        $r = Resolve-UserPathExtForUninstall -CurrentUserPathExt '.CUSTOM;.PS1' -Stamp $stamp
        $r.Action | Should -Be 'remove-entry'
        $r.Value  | Should -Be '.CUSTOM'
    }
}
