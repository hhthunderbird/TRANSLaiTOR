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
