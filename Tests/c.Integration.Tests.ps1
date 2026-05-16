BeforeAll {
    . (Join-Path $PSScriptRoot 'integration/_helpers.ps1')
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Assert-PathOrderingGate -TestDrive $TestDrive -RepoRoot $script:repoRoot
    $script:fixtures = Join-Path $script:repoRoot 'Tests/integration/fixtures'
}

Describe 'c.ps1 -NoRefine (compiler-only)' {
    It 'invokes only the compiler, writes valid XML to stdout, populates state under TestDrive' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-NoRefine','-Raw','sistema ecs unity')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-opt')
        $r.StdOut      | Should -Match '<task>fixture task body</task>'
        Test-Path $r.HistoryPath | Should -BeTrue
        (Get-ChildItem -LiteralPath $r.CacheDir -File).Count | Should -BeGreaterThan 0
    }
}

Describe 'c.ps1 refiner passthrough -> compiler' {
    It 'invokes refiner then compiler, both invocations recorded, XML persisted in history' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-passthrough-valid.json') `
            -Args @('sistema ecs unity 3d game')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')
        Test-Path $r.HistoryPath | Should -BeTrue
        $hist = Get-Content -LiteralPath $r.HistoryPath -Raw | ConvertFrom-Json
        $hist.xml | Should -Match '<task>fixture task body</task>'
    }
}
