#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . $PSScriptRoot\..\Tools\Compare-RefinerBench.ps1

    # Helper to build a synthetic case object matching the bench json shape.
    function New-Case {
        param(
            [string]   $Id,
            [string]   $ExpectedMode = 'passthrough',
            $AcceptableModes = $null,       # $null, omitted, or an array
            [int]      $Trials = 20,
            [hashtable]$ModeCounts = @{ passthrough = 0; questions = 0; invalid = 0 },
            [switch]   $OmitAcceptable
        )
        $h = [ordered]@{
            id           = $Id
            expectedMode = $ExpectedMode
            trials       = $Trials
            modeCounts   = $ModeCounts
        }
        if (-not $OmitAcceptable) {
            $h['acceptableModes'] = $AcceptableModes
        }
        return [PSCustomObject]$h
    }
}

Describe 'Get-CaseMetrics — maxModeShare math' {
    It 'returns 1.0 for fully deterministic {pt:10}/10' {
        $c = New-Case -Id 'a' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        (Get-CaseMetrics -Case $c).maxModeShare | Should -Be 1.0
    }
    It 'returns 0.5 for an even split {pt:5,q:5}/10' {
        $c = New-Case -Id 'b' -Trials 10 -ModeCounts @{ passthrough = 5; questions = 5; invalid = 0 }
        (Get-CaseMetrics -Case $c).maxModeShare | Should -Be 0.5
    }
    It 'returns 0.7 for {pt:7,q:2,inv:1}/10' {
        $c = New-Case -Id 'c' -Trials 10 -ModeCounts @{ passthrough = 7; questions = 2; invalid = 1 }
        (Get-CaseMetrics -Case $c).maxModeShare | Should -Be 0.7
    }
}

Describe 'Get-CaseMetrics — dominantMode tie-break' {
    It 'prefers passthrough over questions on a tie' {
        $c = New-Case -Id 'd' -Trials 10 -ModeCounts @{ passthrough = 5; questions = 5; invalid = 0 }
        (Get-CaseMetrics -Case $c).dominantMode | Should -Be 'passthrough'
    }
    It 'prefers questions over invalid on a tie' {
        $c = New-Case -Id 'e' -Trials 10 -ModeCounts @{ passthrough = 0; questions = 5; invalid = 5 }
        (Get-CaseMetrics -Case $c).dominantMode | Should -Be 'questions'
    }
}

Describe 'Get-CaseMetrics — expectedHit' {
    It 'uses acceptableModes when present and non-empty' {
        $c = New-Case -Id 'f' -ExpectedMode 'passthrough' -AcceptableModes @('passthrough', 'questions') `
            -Trials 10 -ModeCounts @{ passthrough = 3; questions = 7; invalid = 0 }
        (Get-CaseMetrics -Case $c).expectedHit | Should -Be 1.0
    }
    It 'falls back to expectedMode when acceptableModes is null' {
        $c = New-Case -Id 'g' -ExpectedMode 'passthrough' -AcceptableModes $null `
            -Trials 10 -ModeCounts @{ passthrough = 6; questions = 4; invalid = 0 }
        (Get-CaseMetrics -Case $c).expectedHit | Should -Be 0.6
    }
    It 'falls back to expectedMode when acceptableModes is entirely absent' {
        $c = New-Case -Id 'g2' -ExpectedMode 'passthrough' -OmitAcceptable `
            -Trials 10 -ModeCounts @{ passthrough = 6; questions = 4; invalid = 0 }
        (Get-CaseMetrics -Case $c).expectedHit | Should -Be 0.6
    }
    It 'falls back to expectedMode when acceptableModes is an empty array' {
        $c = New-Case -Id 'g3' -ExpectedMode 'passthrough' -AcceptableModes @() `
            -Trials 10 -ModeCounts @{ passthrough = 6; questions = 4; invalid = 0 }
        (Get-CaseMetrics -Case $c).expectedHit | Should -Be 0.6
    }
    It 'reads modeCounts from a PSCustomObject (JSON-parsed shape)' {
        $c = New-Case -Id 'g4' -ExpectedMode 'passthrough' `
            -ModeCounts $null -Trials 10
        $c.modeCounts = [PSCustomObject]@{ passthrough = 8; questions = 2; invalid = 0 }
        (Get-CaseMetrics -Case $c).expectedHit | Should -Be 0.8
    }
}

Describe 'Compare-RefinerBench — rejected cases are skipped' {
    It 'omits rejected (trials=0) cases from output rows' {
        $rejected = New-Case -Id 'rej' -ExpectedMode 'rejected' -Trials 0 -ModeCounts @{}
        $live     = New-Case -Id 'live' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $rows = Compare-RefinerBench -BaselineCases @($rejected, $live) -CandidateCases @($rejected, $live)
        $rows.id | Should -Be 'live'
        ($rows | Where-Object { $_.id -eq 'rej' }) | Should -BeNullOrEmpty
    }
}

Describe 'Compare-RefinerBench — regression rules' {
    It 'flags a regression when drop exceeds threshold' {
        $b = New-Case -Id 'r1' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 } # hit 1.0
        $c = New-Case -Id 'r1' -Trials 10 -ModeCounts @{ passthrough = 5;  questions = 5; invalid = 0 } # hit 0.5
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c) -DropThreshold 0.40
        $row.isRegression | Should -BeTrue
        $row.regressionReason | Should -Match 'threshold'
    }
    It 'does NOT flag when drop is within threshold' {
        $b = New-Case -Id 'r2' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 } # 1.0
        $c = New-Case -Id 'r2' -Trials 10 -ModeCounts @{ passthrough = 7;  questions = 3; invalid = 0 } # 0.7, drop 0.30
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c) -DropThreshold 0.40
        $row.isRegression | Should -BeFalse
        $row.regressionReason | Should -Be ''
    }
    It 'flags a regression via the absolute floor (drop within threshold)' {
        # baseline 0.9, candidate 0.55: drop 0.35 (<= 0.40 threshold) BUT below 0.60 floor.
        $b = New-Case -Id 'r3' -Trials 20 -ModeCounts @{ passthrough = 18; questions = 2;  invalid = 0 } # 0.90
        $c = New-Case -Id 'r3' -Trials 20 -ModeCounts @{ passthrough = 11; questions = 9;  invalid = 0 } # 0.55
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c) -DropThreshold 0.40 -AbsoluteFloor 0.60
        $row.isRegression | Should -BeTrue
        $row.regressionReason | Should -Match 'floor'
    }
    It 'reports BOTH the drop AND the floor reason when both rules fire' {
        # baseline expectedHit 1.0, candidate 0.50:
        #   drop = 0.50 > DropThreshold 0.40  -> drop rule fires
        #   candidate 0.50 < AbsoluteFloor 0.60 while baseline 1.0 >= 0.60 -> floor rule fires
        $b = New-Case -Id 'rboth' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 } # 1.0
        $c = New-Case -Id 'rboth' -Trials 10 -ModeCounts @{ passthrough = 5;  questions = 5; invalid = 0 } # 0.5
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c) -DropThreshold 0.40 -AbsoluteFloor 0.60
        $row.isRegression | Should -BeTrue
        # Both load-bearing substrings must be present (floor must not be hidden by the drop branch).
        $row.regressionReason | Should -Match 'exceeds threshold'
        $row.regressionReason | Should -Match 'fell below absolute floor'
    }
    It 'reports ONLY the drop reason when the floor rule does not apply' {
        # baseline 1.0 -> candidate 0.5: drop 0.50 > 0.40, but floor lowered to 0.30 so floor rule is inactive.
        $b = New-Case -Id 'rdrop' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $c = New-Case -Id 'rdrop' -Trials 10 -ModeCounts @{ passthrough = 5;  questions = 5; invalid = 0 }
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c) -DropThreshold 0.40 -AbsoluteFloor 0.30
        $row.isRegression | Should -BeTrue
        $row.regressionReason | Should -Match 'exceeds threshold'
        $row.regressionReason | Should -Not -Match 'fell below absolute floor'
    }
    It 'does not throw and yields finite zero shares for a malformed LIVE candidate case with trials = 0' {
        # A non-rejected case whose trials is 0 (malformed bench output) must not divide-by-zero.
        # It surfaces as a row with guarded zero shares (not skipped, not NaN/Infinity).
        $b = New-Case -Id 'mal' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $c = New-Case -Id 'mal' -ExpectedMode 'passthrough' -Trials 0 -ModeCounts @{ passthrough = 0; questions = 0; invalid = 0 }
        { Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c) } | Should -Not -Throw
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @($c)
        $row | Should -Not -BeNullOrEmpty
        $row.candidateMaxShare    | Should -Be 0
        $row.candidateExpectedHit | Should -Be 0
        [double]::IsNaN([double]$row.candidateMaxShare)        | Should -BeFalse
        [double]::IsInfinity([double]$row.candidateMaxShare)   | Should -BeFalse
        [double]::IsNaN([double]$row.candidateExpectedHit)     | Should -BeFalse
        [double]::IsInfinity([double]$row.candidateExpectedHit)| Should -BeFalse
    }
    It 'computes finite guarded shares directly for a trials = 0 case via Get-CaseMetricsGuarded' {
        # The guarded metric path treats trials <= 0 as zero shares rather than dividing.
        $c = New-Case -Id 'z' -ExpectedMode 'passthrough' -Trials 0 -ModeCounts @{ passthrough = 0; questions = 0; invalid = 0 }
        $m = Get-CaseMetricsGuarded -Case $c
        $m.maxModeShare | Should -Be 0
        $m.expectedHit  | Should -Be 0
        [double]::IsNaN([double]$m.maxModeShare) | Should -BeFalse
    }
    It 'flags a case missing from the candidate run' {
        $b = New-Case -Id 'r4' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $row = Compare-RefinerBench -BaselineCases @($b) -CandidateCases @()
        $row.isRegression | Should -BeTrue
        $row.regressionReason | Should -Be 'missing from candidate run'
    }
    It 'includes a new (candidate-only) case with null baseline fields and no regression' {
        $c = New-Case -Id 'new1' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $row = Compare-RefinerBench -BaselineCases @() -CandidateCases @($c)
        $row.id | Should -Be 'new1'
        $row.baselineMaxShare | Should -BeNullOrEmpty
        $row.baselineExpectedHit | Should -BeNullOrEmpty
        $row.dominantModeBaseline | Should -BeNullOrEmpty
        $row.candidateMaxShare | Should -Be 1.0
        $row.isRegression | Should -BeFalse
    }
}

Describe 'Get-RefinerBenchSummary' {
    It 'is a pareto winner when watched bimodals improve and there are no regressions' {
        # two watched bimodal ids improve 0.5 -> 1.0; one stable non-watched case
        $bm1b = New-Case -Id 'bm1' -Trials 10 -ModeCounts @{ passthrough = 5; questions = 5; invalid = 0 }
        $bm1c = New-Case -Id 'bm1' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $bm2b = New-Case -Id 'bm2' -Trials 10 -ModeCounts @{ passthrough = 5; questions = 5; invalid = 0 }
        $bm2c = New-Case -Id 'bm2' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $stb  = New-Case -Id 'st'  -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $stc  = New-Case -Id 'st'  -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }

        $rows = Compare-RefinerBench -BaselineCases @($bm1b, $bm2b, $stb) -CandidateCases @($bm1c, $bm2c, $stc)
        $summary = Get-RefinerBenchSummary -Rows $rows -BimodalIds @('bm1', 'bm2')

        $summary.regressionCount | Should -Be 0
        $summary.bimodalImproved.Count | Should -Be 2
        $summary.isParetoWinner | Should -BeTrue
    }

    It 'is NOT a pareto winner when any regression is present' {
        $bm1b = New-Case -Id 'bm1' -Trials 10 -ModeCounts @{ passthrough = 5;  questions = 5; invalid = 0 }
        $bm1c = New-Case -Id 'bm1' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        # a regressed case: 1.0 -> 0.4 (drop 0.60 > 0.40)
        $rgb  = New-Case -Id 'rg' -Trials 10 -ModeCounts @{ passthrough = 10; questions = 0; invalid = 0 }
        $rgc  = New-Case -Id 'rg' -Trials 10 -ModeCounts @{ passthrough = 4;  questions = 6; invalid = 0 }

        $rows = Compare-RefinerBench -BaselineCases @($bm1b, $rgb) -CandidateCases @($bm1c, $rgc)
        $summary = Get-RefinerBenchSummary -Rows $rows -BimodalIds @('bm1')

        $summary.regressionCount | Should -Be 1
        $summary.regressions | Should -Contain 'rg'
        $summary.isParetoWinner | Should -BeFalse
    }
}
