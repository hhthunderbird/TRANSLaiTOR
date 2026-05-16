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

Describe 'c.ps1 cache behavior' {
    It 'second run with same args serves compiler output from cache (refiner still runs)' {
        $fixture = Join-Path $script:fixtures 'combo-passthrough-valid.json'

        $run1 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('sistema ecs unity 3d game')
        $run1.ExitCode    | Should -Be 0
        $run1.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        # Re-run with the SAME $TestDrive so cache+state carry over. Note:
        # Invoke-CIntegration resets invocations.txt at the start of each call,
        # so $run2.Invocations reflects only what happened during run2.
        $run2 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('sistema ecs unity 3d game')
        $run2.ExitCode    | Should -Be 0
        $run2.Invocations | Should -Be @('prompt-refiner')   # compiler served from cache
    }

    It '-NoCache on second run forces compiler call even when cache file exists' {
        $fixture = Join-Path $script:fixtures 'combo-passthrough-valid.json'

        # run1's cache is already warm from It #1 above (Pester 5 $TestDrive is
        # per-Describe, not per-It, so cache files persist across It blocks in
        # the same Describe). Asserting run1's invocations = just the refiner
        # locks in that cache is genuinely doing its job; a broken cache would
        # make run1 record both invocations and fail this line before run2.
        $run1 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('sistema ecs unity 3d game')
        $run1.Invocations | Should -Be @('prompt-refiner')

        $run2 = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture $fixture `
            -Args @('-NoCache','sistema ecs unity 3d game')
        $run2.Invocations | Should -Be @('prompt-refiner','prompt-opt')
    }
}

Describe 'c.ps1 refiner Q&A flow' {
    It 'with -Interactive and stdin answer, history.input reflects merged answer' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-questions-valid.json') `
            -Args @('-Interactive','cache management strategy options') `
            -StdIn "redis local`n"

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        # history.jsonl is append-only; this is the first It in the Describe so only 1 line exists.
        $histLine = Get-Content -LiteralPath $r.HistoryPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $hist = $histLine | ConvertFrom-Json
        $hist.input   | Should -Match 'redis local'
        $hist.refined | Should -BeTrue
    }

    It 'without -Interactive (default), refiner questions are skipped and raw input is used' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'combo-questions-valid.json') `
            -Args @('cache management strategy options')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-refiner','prompt-opt')

        # Read last line — $TestDrive persists from It #1, so history.jsonl now has 2 entries.
        $histLine = Get-Content -LiteralPath $r.HistoryPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $hist = $histLine | ConvertFrom-Json
        $hist.input   | Should -Be 'cache management strategy options'
        $hist.refined | Should -BeFalse

        # The metrics line for run2 should record metricMode='questions-skip'.
        # metrics.jsonl is also append-only — read the last line.
        $metricsLine = Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $metrics = $metricsLine | ConvertFrom-Json
        $metrics.mode | Should -Be 'questions-skip'
    }
}

Describe 'c.ps1 frictionless fallback' {
    It 'when compiler emits non-XML, c.ps1 emits AVISO and uses raw input as XML payload' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-fallback-nonxml.json') `
            -Args @('-NoRefine','sistema ecs unity')

        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match 'AVISO: otimizador nao produziu XML valido'

        # Fallback runs are NOT cached (c.ps1:248 comment).
        if (Test-Path $r.CacheDir) {
            (Get-ChildItem -LiteralPath $r.CacheDir -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        # metrics.jsonl: read last line (defensively filter blanks).
        $metricsLine = Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $metrics = $metricsLine | ConvertFrom-Json
        $metrics.mode | Should -Be 'fallback'
    }
}

Describe 'c.ps1 -Send' {
    It 'exits 8 with error message when claude is not on PATH' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Send','-NoRefine','sistema ecs unity') `
            -Stubs @('ollama')   # NB: no claude staged

        $r.ExitCode | Should -Be 8
        $r.StdOut   | Should -Match "'claude' CLI nao encontrado"
        $r.Invocations | Should -Not -Contain 'claude'
    }

    It 'with claude on PATH, pipes XML and exits with claude exit code' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Send','-NoRefine','sistema ecs unity') `
            -Stubs @('ollama','claude')

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Contain 'claude'
    }
}

Describe 'c.ps1 zero-signal pre-gate' {
    It 'with -Interactive and short input, pre-gate Q runs, refiner is skipped, only compiler invokes' {
        $r = Invoke-CIntegration `
            -TestDrive $TestDrive `
            -RepoRoot $script:repoRoot `
            -Fixture (Join-Path $script:fixtures 'compiler-valid-xml.json') `
            -Args @('-Interactive','cache') `
            -StdIn "area backend, problema slow query, stack postgres`n"

        $r.ExitCode    | Should -Be 0
        $r.Invocations | Should -Be @('prompt-opt')   # refiner SKIPPED by pre-gate

        $histLine = Get-Content -LiteralPath $r.HistoryPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $hist = $histLine | ConvertFrom-Json
        $hist.input | Should -Match 'postgres'
        $hist.refined | Should -BeTrue

        $metricsLine = Get-Content -LiteralPath $r.MetricsPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $metrics = $metricsLine | ConvertFrom-Json
        $metrics.mode | Should -Be 'pregate'
    }
}
