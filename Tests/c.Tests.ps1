BeforeAll {
    $here = $PSScriptRoot
    $repoRoot = Split-Path -Parent $here
    $script:cPs1 = Join-Path $repoRoot 'c.ps1'

    # Subprocess driver: invoke c.ps1 under a fresh powershell.exe with an
    # isolated USERPROFILE (state dir = $isolatedHome\.cprompt) and an
    # optional PATH override (used to hide `claude` for -Send tests).
    function Invoke-CScript {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Args,
            [Parameter(Mandatory)][string]$IsolatedHome,
            [string]$PathOverride
        )
        if (-not (Test-Path -LiteralPath $IsolatedHome)) {
            New-Item -ItemType Directory -Path $IsolatedHome -Force | Out-Null
        }

        $psArgs = @('-NoProfile', '-NonInteractive', '-File', $script:cPs1)
        if ($Args -and $Args.Count -gt 0) { $psArgs += $Args }

        $prevHome = $env:USERPROFILE
        $prevPath = $env:PATH
        try {
            $env:USERPROFILE = $IsolatedHome
            if ($PSBoundParameters.ContainsKey('PathOverride')) {
                $env:PATH = $PathOverride
            }
            $tmpOut = [System.IO.Path]::GetTempFileName()
            $tmpErr = "$tmpOut.err"
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $tmpOut `
                -RedirectStandardError $tmpErr
            $exit = $proc.ExitCode
            $stdout = (Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue) +
                      (Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue)
            Remove-Item -LiteralPath $tmpOut, $tmpErr -ErrorAction SilentlyContinue
        } finally {
            $env:USERPROFILE = $prevHome
            $env:PATH = $prevPath
        }

        return [pscustomobject]@{ ExitCode = $exit; StdOut = $stdout }
    }
}

Describe 'c.ps1 -Help' {
    It 'exits 0 and prints the usage banner' {
        $tmpHome = Join-Path $TestDrive 'home-help'
        $res = Invoke-CScript -Args @('-Help') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $res.StdOut   | Should -Match 'TRANSLaiTOR'
        $res.StdOut   | Should -Match 'uso:'
    }
}

Describe 'c.ps1 with no prompt (clipboard mode)' {
    BeforeAll {
        # Extend Invoke-CScript to accept ClipboardOverride env var.
        function Invoke-CScript-Clip {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Args,
                [Parameter(Mandatory)][string]$IsolatedHome,
                [string]$ClipboardText = ''
            )
            if (-not (Test-Path -LiteralPath $IsolatedHome)) {
                New-Item -ItemType Directory -Path $IsolatedHome -Force | Out-Null
            }
            $psArgs = @('-NoProfile', '-NonInteractive', '-File', $script:cPs1)
            if ($Args -and $Args.Count -gt 0) { $psArgs += $Args }

            $prevHome = $env:USERPROFILE
            $prevClip = $env:CPROMPT_TEST_CLIPBOARD
            $prevClipOverride = $env:CPROMPT_CLIPBOARD_OVERRIDE
            try {
                $env:USERPROFILE = $IsolatedHome
                $env:CPROMPT_CLIPBOARD_OVERRIDE = '1'
                $env:CPROMPT_TEST_CLIPBOARD = $ClipboardText
                $tmpOut = [System.IO.Path]::GetTempFileName()
                $tmpErr = "$tmpOut.err"
                $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
                    -NoNewWindow -Wait -PassThru `
                    -RedirectStandardOutput $tmpOut `
                    -RedirectStandardError $tmpErr
                $exit = $proc.ExitCode
                $stdout = (Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue) +
                          (Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue)
                Remove-Item -LiteralPath $tmpOut, $tmpErr -ErrorAction SilentlyContinue
            } finally {
                $env:USERPROFILE = $prevHome
                $env:CPROMPT_TEST_CLIPBOARD = $prevClip
                $env:CPROMPT_CLIPBOARD_OVERRIDE = $prevClipOverride
            }
            return [pscustomobject]@{ ExitCode = $exit; StdOut = $stdout }
        }
    }

    It 'exits 1 with error message when clipboard is empty and no prompt supplied' {
        $tmpHome = Join-Path $TestDrive 'home-clip-empty'
        $res = Invoke-CScript-Clip -Args @() -IsolatedHome $tmpHome -ClipboardText ''
        $res.ExitCode | Should -Be 1
        $res.StdOut   | Should -Match '(?i)clipboard'
    }

    It 'uses clipboard content when no prompt supplied (non-interactive/redirected)' {
        $tmpHome = Join-Path $TestDrive 'home-clip-content'
        # Need ollama stub for compilation
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $clipText = 'implement a REST endpoint for users'
        $res = Invoke-CScript-Clip -Args @('-NoRefine', '-Raw') -IsolatedHome $tmpHome -ClipboardText $clipText
        # Should attempt to process (may fail at ollama, but should NOT show usage/clipboard-empty error)
        $res.StdOut | Should -Not -Match '(?i)clipboard vazio'
        $res.ExitCode | Should -Not -Be 1
    }

    It 'shows clipboard preview with char count' {
        $tmpHome = Join-Path $TestDrive 'home-clip-preview'
        $multiLine = "line1`nline2`nline3`nline4`nline5`nline6`nline7`nline8"
        $res = Invoke-CScript-Clip -Args @('-NoRefine', '-Raw') -IsolatedHome $tmpHome -ClipboardText $multiLine
        # In non-interactive (subprocess), skips prompt but should still show preview indicator
        $res.StdOut | Should -Match '(?i)clipboard.*\d+.*char'
    }
}

Describe 'c.ps1 input validation' {
    It 'exits 1 on input that exceeds MaxInputChars (4000)' {
        $tmpHome = Join-Path $TestDrive 'home-oversize'
        $oversized = 'x' * 5000
        $res = Invoke-CScript -Args @($oversized) -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 1
        $res.StdOut   | Should -Match '(?i)invalido'
    }
}

Describe 'c.ps1 -Last' {
    It 'exits 7 with "historico vazio" when no history exists' {
        $tmpHome = Join-Path $TestDrive 'home-emptyhist'
        $res = Invoke-CScript -Args @('-Last') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 7
        $res.StdOut   | Should -Match '(?i)historico vazio'
    }

    It 'exits 0 and prints the last XML when a history entry exists' {
        $tmpHome = Join-Path $TestDrive 'home-hist'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $historyPath = Join-Path $stateDir 'history.jsonl'
        $entry = [ordered]@{
            ts    = '2026-05-14T12:00:00Z'
            model = 'prompt-opt'
            xml   = '<task>R</task><context>S</context><constraints>T</constraints>'
        }
        $line = ($entry | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($historyPath, "$line`n", (New-Object System.Text.UTF8Encoding($false)))

        $res = Invoke-CScript -Args @('-Last', '-Raw') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $res.StdOut   | Should -Match '<task>R</task>'
        $res.StdOut   | Should -Match '<constraints>T</constraints>'
    }
}

Describe 'c.ps1 zero-friction default (Q&A is opt-in)' {
    # Regression suite for friction reports from interactive terminal use.
    # All tests run under `powershell.exe -NoProfile -NonInteractive` via
    # the existing Invoke-CScript driver. In that mode any unsuppressed
    # Read-Host throws a terminating error, which would surface as a
    # non-zero exit. A clean exit therefore PROVES no Read-Host was hit
    # (and only the new default-skip behaviour can deliver that without
    # the caller explicitly passing -NonInteractive).

    It 'meta-question prompt does not block on refiner Q&A (case A)' {
        $tmpHome = Join-Path $TestDrive 'home-case-a'
        # No interactive flag. Real user input that previously hit a
        # refiner-questions block from an interactive terminal. Must
        # exit 0 (compiler XML or raw fallback), NOT crash on Read-Host.
        $res = Invoke-CScript -Args @('-Raw', 'qual é a nossa próxima tarefa na lista?') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        # stdout must contain SOMETHING (either valid XML or raw fallback)
        $res.StdOut.Trim().Length -gt 0 | Should -Be $true
    }

    It 'conversational/meta prompt without -Raw still terminates without Q&A hang (case B)' {
        $tmpHome = Join-Path $TestDrive 'home-case-b'
        $res = Invoke-CScript -Args @('Não, eu quero que teste os casos que deram erro comigo') -IsolatedHome $tmpHome
        # Without -Raw the refiner runs. If it picks 'questions' mode and
        # default still blocks, this would crash with a Read-Host error.
        # With the new opt-in default it must exit 0 and proceed to the
        # compiler (or fall back to raw input).
        $res.ExitCode | Should -Be 0
    }

    It 'short input (<4 words) does not block on zero-signal pre-gate by default' {
        $tmpHome = Join-Path $TestDrive 'home-pregate-default'
        # Previously the pre-gate fired Read-Host unconditionally; the only
        # escape was -NonInteractive. New default must auto-skip the Q&A.
        $res = Invoke-CScript -Args @('go') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
    }

    It '-Interactive flag is documented in the help banner' {
        # We CAN'T positively assert Read-Host fires in a -NonInteractive
        # subprocess (it'd just crash). Document the contract instead: if
        # the user opts in, they accept the blocking semantics. The flag
        # exists and is recognised; we just verify help text mentions it.
        # Word-boundary match to avoid matching -NonInteractive.
        $tmpHome = Join-Path $TestDrive 'home-help-interactive'
        $res = Invoke-CScript -Args @('-Help') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $res.StdOut   | Should -Match '(?<![A-Za-z])-Interactive\b'
    }
}

Describe 'c.ps1 -MetaQuery' {
    It 'exits 0 and returns synthetic XML with project context' {
        $tmpHome = Join-Path $TestDrive 'home-mq-forced'
        $res = Invoke-CScript -Args @('-MetaQuery', '-Raw', 'o que temos para fazer agora?') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match '<task>'
        $res.StdOut | Should -Match '<context>'
        $res.StdOut | Should -Match '<constraints>'
    }

    It 'includes branch and git status in context' {
        $tmpHome = Join-Path $TestDrive 'home-mq-context'
        $res = Invoke-CScript -Args @('-MetaQuery', '-Raw', 'o que falta fazer?') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match 'Branch:'
    }

    It 'skips Ollama entirely (no compiler/refiner error when ollama absent)' {
        $tmpHome = Join-Path $TestDrive 'home-mq-noollama'
        # Use PathOverride to hide ollama from PATH — meta-query path must not need it
        $minPath = [System.IO.Path]::GetDirectoryName((Get-Command powershell.exe).Source)
        $gitPath = [System.IO.Path]::GetDirectoryName((Get-Command git).Source)
        $safePath = "$minPath;$gitPath"
        $res = Invoke-CScript -Args @('-MetaQuery', '-Raw', 'qual o status?') -IsolatedHome $tmpHome -PathOverride $safePath
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match '<task>'
    }

    It 'auto-detects meta-query without -MetaQuery flag' {
        $tmpHome = Join-Path $TestDrive 'home-mq-auto'
        $res = Invoke-CScript -Args @('-Raw', 'o que temos para fazer agora?') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match '<task>Responder consulta de status'
    }

    It 'records contextGatherMs in metrics' {
        $tmpHome = Join-Path $TestDrive 'home-mq-metrics'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $res = Invoke-CScript -Args @('-MetaQuery', '-Raw', 'qual o proximo passo?') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
        $metricsPath = Join-Path $stateDir 'metrics.jsonl'
        Test-Path $metricsPath | Should -Be $true
        $lastLine = Get-Content $metricsPath -Tail 1 -Encoding utf8
        $metric = $lastLine | ConvertFrom-Json
        $metric.mode | Should -Be 'meta-query'
        $metric.contextGatherMs | Should -BeGreaterOrEqual 0
    }
}

Describe 'c.ps1 -NonInteractive (legacy alias, now a no-op)' {
    # Default is non-interactive, so -NonInteractive behaves identically to
    # not passing it. Tests here just verify the flag is still accepted
    # without error (hook installs that still pass it must not break).

    It 'accepts -NonInteractive without parameter-binding errors' {
        $tmpHome = Join-Path $TestDrive 'home-noni-alias'
        $res = Invoke-CScript -Args @('-NonInteractive', '-Raw', '-NoRefine', 'sistema de tiro no ecs unity') -IsolatedHome $tmpHome
        $res.ExitCode | Should -Be 0
    }
}

Describe 'c.ps1 conversational bypass' {
    It 'emits empty stdout for a continuation prompt under -Raw (no ollama)' {
        $tmpHome = Join-Path $TestDrive 'home-conv-raw'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        # PathOverride hides ollama: bypass must not need the compiler at all.
        $safePath = Split-Path (Get-Command powershell.exe).Source
        $res = Invoke-CScript -Args @('-Raw', 'vamos continuar de onde paramos') -IsolatedHome $tmpHome -PathOverride $safePath
        $res.ExitCode | Should -Be 0
        ([string]$res.StdOut).Trim() | Should -BeNullOrEmpty
    }

    It 'records mode=conversational in metrics' {
        $tmpHome = Join-Path $TestDrive 'home-conv-metric'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $safePath = Split-Path (Get-Command powershell.exe).Source
        $res = Invoke-CScript -Args @('-Raw', 'vamos na ordem') -IsolatedHome $tmpHome -PathOverride $safePath
        $res.ExitCode | Should -Be 0
        $metricsPath = Join-Path $stateDir 'metrics.jsonl'
        $lastLine = Get-Content $metricsPath -Tail 1 -Encoding utf8
        $metric = $lastLine | ConvertFrom-Json
        $metric.mode | Should -Be 'conversational'
    }

    It 'does not call claude for -Send on a continuation prompt' {
        $tmpHome = Join-Path $TestDrive 'home-conv-send'
        $stateDir = Join-Path $tmpHome '.cprompt'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $safePath = Split-Path (Get-Command powershell.exe).Source
        $res = Invoke-CScript -Args @('-Send', 'vamos continuar') -IsolatedHome $tmpHome -PathOverride $safePath
        $res.ExitCode | Should -Be 0
        ([string]$res.StdOut) | Should -Match 'vamos continuar'
    }
}
