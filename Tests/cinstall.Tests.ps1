$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path (Split-Path -Parent $here) 'cinstall.psm1'
Remove-Module cinstall -ErrorAction SilentlyContinue
Import-Module $module -Force

Describe 'Test-PathContainsEntry' {
    It 'returns $true when the entry appears verbatim' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B;C:\C' -Entry 'C:\B' | Should Be $true
    }

    It 'returns $false when the entry is absent' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should Be $false
    }

    It 'matches case-insensitively' {
        Test-PathContainsEntry -PathString 'C:\Users\HHTHU\Scripts' -Entry 'c:\users\hhthu\scripts' | Should Be $true
    }

    It 'tolerates a trailing semicolon in the PathString' {
        Test-PathContainsEntry -PathString 'C:\A;C:\B;' -Entry 'C:\B' | Should Be $true
    }

    It 'matches a whole segment, not a substring' {
        # "C:\B" must NOT match inside "C:\Bin".
        Test-PathContainsEntry -PathString 'C:\A;C:\Bin' -Entry 'C:\B' | Should Be $false
    }

    It 'returns $false on an empty PathString' {
        Test-PathContainsEntry -PathString '' -Entry 'C:\A' | Should Be $false
    }

    It 'treats a null PathString as empty' {
        Test-PathContainsEntry -PathString $null -Entry 'C:\A' | Should Be $false
    }
}

Describe 'Add-PathEntry' {
    It 'appends to a non-empty PathString with a separating semicolon' {
        Add-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should Be 'C:\A;C:\B;C:\C'
    }

    It 'returns just the entry when PathString is empty' {
        Add-PathEntry -PathString '' -Entry 'C:\A' | Should Be 'C:\A'
    }

    It 'returns just the entry when PathString is null' {
        Add-PathEntry -PathString $null -Entry 'C:\A' | Should Be 'C:\A'
    }

    It 'returns the PathString unchanged when the entry is already present' {
        Add-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\B' | Should Be 'C:\A;C:\B'
    }

    It 'is case-insensitive when checking for existing presence' {
        Add-PathEntry -PathString 'C:\users\HHTHU\Scripts' -Entry 'C:\Users\hhthu\scripts' | Should Be 'C:\users\HHTHU\Scripts'
    }

    It 'strips a single trailing semicolon before appending' {
        Add-PathEntry -PathString 'C:\A;C:\B;' -Entry 'C:\C' | Should Be 'C:\A;C:\B;C:\C'
    }
}

Describe 'Remove-PathEntry' {
    It 'removes a middle entry and rejoins with semicolons' {
        Remove-PathEntry -PathString 'C:\A;C:\B;C:\C' -Entry 'C:\B' | Should Be 'C:\A;C:\C'
    }

    It 'removes a leading entry' {
        Remove-PathEntry -PathString 'C:\B;C:\A' -Entry 'C:\B' | Should Be 'C:\A'
    }

    It 'removes a trailing entry' {
        Remove-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\B' | Should Be 'C:\A'
    }

    It 'returns the PathString unchanged when the entry is absent' {
        Remove-PathEntry -PathString 'C:\A;C:\B' -Entry 'C:\C' | Should Be 'C:\A;C:\B'
    }

    It 'matches case-insensitively when removing' {
        Remove-PathEntry -PathString 'C:\A;C:\Users\hhthu\Scripts;C:\C' -Entry 'c:\users\hhthu\scripts' |
            Should Be 'C:\A;C:\C'
    }

    It 'removes all duplicate occurrences' {
        Remove-PathEntry -PathString 'C:\A;C:\B;C:\B;C:\C' -Entry 'C:\B' | Should Be 'C:\A;C:\C'
    }

    It 'returns an empty string when only the entry was present' {
        Remove-PathEntry -PathString 'C:\B' -Entry 'C:\B' | Should Be ''
    }

    It 'returns an empty string when PathString is null' {
        Remove-PathEntry -PathString $null -Entry 'C:\B' | Should Be ''
    }

    It 'preserves a non-matching segment that contains the entry as a substring' {
        # "C:\B" must NOT remove "C:\Bin".
        Remove-PathEntry -PathString 'C:\Bin;C:\B' -Entry 'C:\B' | Should Be 'C:\Bin'
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
        Test-PathExtShouldRemove -PathExtString '.COM;.EXE;.PS1' -Entry '.PS1' -StampPath $script:tmpStamp | Should Be $false
    }

    It 'returns $false when the stamp exists but the entry is absent (idempotent no-op)' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString '.COM;.EXE' -Entry '.PS1' -StampPath $script:tmpStamp | Should Be $false
    }

    It 'returns $true when the stamp exists and the entry is present' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString '.COM;.EXE;.PS1' -Entry '.PS1' -StampPath $script:tmpStamp | Should Be $true
    }

    It 'matches the entry case-insensitively' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString '.COM;.exe;.ps1' -Entry '.PS1' -StampPath $script:tmpStamp | Should Be $true
    }

    It 'returns $false on a null PathExtString even with stamp present' {
        New-Item -ItemType File -Path $script:tmpStamp -Force | Out-Null
        Test-PathExtShouldRemove -PathExtString $null -Entry '.PS1' -StampPath $script:tmpStamp | Should Be $false
    }
}

Describe 'Get-InstallRecoveryHint' {
    It 'embeds the reason and exit code in the header' {
        $hint = Get-InstallRecoveryHint -Code 4 -Reason 'ollama create falhou' -InstallDir 'C:\X'
        $hint | Should Match 'ollama create falhou'
        $hint | Should Match 'codigo 4'
    }

    It 'mentions the install directory so the user knows where partial state lives' {
        $hint = Get-InstallRecoveryHint -Code 2 -Reason 'ollama nao encontrado' -InstallDir 'C:\Users\me\Scripts'
        $hint | Should Match 'C:\\Users\\me\\Scripts'
    }

    It 'suggests re-running install.ps1 as the primary recovery path' {
        $hint = Get-InstallRecoveryHint -Code 5 -Reason 'pull failed' -InstallDir 'C:\X'
        $hint | Should Match 'install\.ps1'
    }

    It 'suggests uninstall.ps1 -PurgeInstall as the cleanup fallback' {
        $hint = Get-InstallRecoveryHint -Code 5 -Reason 'pull failed' -InstallDir 'C:\X'
        $hint | Should Match 'uninstall\.ps1'
        $hint | Should Match 'PurgeInstall'
    }

    It 'tolerates an empty reason without throwing' {
        { Get-InstallRecoveryHint -Code 1 -Reason '' -InstallDir 'C:\X' } | Should Not Throw
    }
}
