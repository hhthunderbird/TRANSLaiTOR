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
