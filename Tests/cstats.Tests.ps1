BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Cstats {
    param(
        [string[]]$CstatsArgs
    )
    $stdOutTmp = Join-Path $TestDrive 'cstats-stdout.txt'
    $stdErrTmp = Join-Path $TestDrive 'cstats-stderr.txt'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $script:repoRoot 'cstats.ps1')) + $CstatsArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
        -RedirectStandardOutput $stdOutTmp `
        -RedirectStandardError $stdErrTmp `
        -Wait -PassThru -NoNewWindow
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = if (Test-Path $stdOutTmp) { Get-Content -LiteralPath $stdOutTmp -Raw } else { '' }
        StdErr   = if (Test-Path $stdErrTmp) { Get-Content -LiteralPath $stdErrTmp -Raw } else { '' }
    }
}

function New-TestMetrics {
    $metricsPath = Join-Path $TestDrive 'test-metrics.jsonl'
    @(
        '{"ts":"2026-05-15T10:00:00.0000000Z","mode":"refiner","model":"prompt-opt","totalMs":3000,"inputChars":100,"xmlChars":300}'
        '{"ts":"2026-05-20T10:00:00.0000000Z","mode":"raw","model":"prompt-opt","totalMs":2000,"inputChars":80,"xmlChars":200}'
        '{"ts":"2026-05-23T10:00:00.0000000Z","mode":"refiner","model":"prompt-refiner","totalMs":4000,"inputChars":120,"xmlChars":350}'
        '{"ts":"2026-05-24T10:00:00.0000000Z","mode":"cache","totalMs":500,"inputChars":50,"xmlChars":150}'
    ) | Set-Content -LiteralPath $metricsPath -Encoding UTF8
    return $metricsPath
}
}

Describe 'cstats.ps1 -Since filtering' {
    It 'filters entries by absolute ISO-8601 date' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-Since','2026-05-22','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'Entries\s*:\s*2'
    }
}

Describe 'cstats.ps1 -By grouping' {
    It 'groups by mode with headers sorted by count descending' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-By','mode','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match '=== mode: refiner \(2 entries\) ==='
        $r.StdOut   | Should -Match '=== mode: raw \(1 entries\) ==='
        $r.StdOut   | Should -Match '=== mode: cache \(1 entries\) ==='
    }

    It 'groups by model with (unknown) for entries missing the field' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-By','model','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match '=== model: prompt-opt \(2 entries\) ==='
        $r.StdOut   | Should -Match '=== model: prompt-refiner \(1 entries\) ==='
        $r.StdOut   | Should -Match '=== model: \(unknown\) \(1 entries\) ==='
    }

    It 'exits 1 on invalid -By value' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-By','invalid','-Path',$metricsPath)
        $r.ExitCode | Should -Be 1
    }
}

Describe 'cstats.ps1 composability' {
    It '-Since applied before -Last' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-Since','2026-05-19','-Last','2','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'Entries\s*:\s*2'
    }

    It '-Since + -By filters then groups' {
        $metricsPath = New-TestMetrics
        $r = Invoke-Cstats -CstatsArgs @('-Since','2026-05-22','-By','mode','-Path',$metricsPath)
        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'Entries\s*:\s*2'
        $r.StdOut   | Should -Match '=== mode: refiner \(1 entries\) ==='
        $r.StdOut   | Should -Match '=== mode: cache \(1 entries\) ==='
        $r.StdOut   | Should -Not -Match '=== mode: raw'
    }
}
