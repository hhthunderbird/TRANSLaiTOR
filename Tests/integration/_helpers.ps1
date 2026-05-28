# Helper module for c.ps1 integration tests. Dot-source from BeforeAll.

function Invoke-CIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TestDrive,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Fixture,
        [string[]]$Args = @(),
        [string[]]$Stubs = @('ollama'),
        [string]$StdIn = '',
        [switch]$CaptureStdin
    )

    # Stage requested stubs into per-test bin dir.
    $binDir = Join-Path $TestDrive 'bin'
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    foreach ($name in $Stubs) {
        $src1 = Join-Path $RepoRoot "Tests/integration/$name.cmd"
        $src2 = Join-Path $RepoRoot "Tests/integration/$name-impl.ps1"
        Copy-Item -LiteralPath $src1 -Destination (Join-Path $binDir "$name.cmd") -Force
        Copy-Item -LiteralPath $src2 -Destination (Join-Path $binDir "$name-impl.ps1") -Force
    }

    # Per-test scratch paths.
    $stateRoot      = Join-Path $TestDrive 'cprompt-state'
    $invocationsPath = Join-Path $TestDrive 'invocations.txt'
    [System.IO.File]::WriteAllText($invocationsPath, '', [System.Text.UTF8Encoding]::new($false))

    $stdInTmp  = Join-Path $TestDrive 'stdin.txt'
    $stdOutTmp = Join-Path $TestDrive 'stdout.txt'
    $stdErrTmp = Join-Path $TestDrive 'stderr.txt'
    Set-Content -LiteralPath $stdInTmp -Value $StdIn -Encoding UTF8 -NoNewline

    # Optional stdin capture: when caller sets $CaptureStdin (true), the stub
    # appends each invocation's stdin to a file we return as .StdInCapture.
    $captureStdinPath = $null
    if ($PSBoundParameters.ContainsKey('CaptureStdin') -and $CaptureStdin) {
        $captureStdinPath = Join-Path $TestDrive 'stub-stdin.txt'
        if (Test-Path $captureStdinPath) { Remove-Item -LiteralPath $captureStdinPath -Force }
    }

    $savedPath = $env:Path
    $savedFixture = $env:CPROMPT_TEST_FIXTURE
    $savedInv = $env:CPROMPT_TEST_INVOCATIONS
    $savedRoot = $env:CPROMPT_STATE_ROOT
    $savedCap = $env:CPROMPT_TEST_CAPTURE_STDIN
    try {
        # Minimal isolated PATH: stubs first, then only OS essentials so child
        # powershell.exe, cmd.exe, and Set-Clipboard can be found, but no
        # dev-installed tools (e.g. real claude.exe) leak in.
        $env:Path = "$binDir;$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
        $env:CPROMPT_TEST_FIXTURE = $Fixture
        $env:CPROMPT_TEST_INVOCATIONS = $invocationsPath
        $env:CPROMPT_STATE_ROOT = $stateRoot
        if ($captureStdinPath) { $env:CPROMPT_TEST_CAPTURE_STDIN = $captureStdinPath }

        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'c.ps1')) + $Args
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
            -RedirectStandardInput $stdInTmp `
            -RedirectStandardOutput $stdOutTmp `
            -RedirectStandardError $stdErrTmp `
            -Wait -PassThru -NoNewWindow
    } finally {
        $env:Path = $savedPath
        if ($null -ne $savedFixture) { $env:CPROMPT_TEST_FIXTURE = $savedFixture } else { Remove-Item Env:\CPROMPT_TEST_FIXTURE -ErrorAction SilentlyContinue }
        if ($null -ne $savedInv) { $env:CPROMPT_TEST_INVOCATIONS = $savedInv } else { Remove-Item Env:\CPROMPT_TEST_INVOCATIONS -ErrorAction SilentlyContinue }
        if ($null -ne $savedRoot) { $env:CPROMPT_STATE_ROOT = $savedRoot } else { Remove-Item Env:\CPROMPT_STATE_ROOT -ErrorAction SilentlyContinue }
        if ($null -ne $savedCap) { $env:CPROMPT_TEST_CAPTURE_STDIN = $savedCap } else { Remove-Item Env:\CPROMPT_TEST_CAPTURE_STDIN -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{
        ExitCode     = $p.ExitCode
        StdOut       = if (Test-Path $stdOutTmp) { Get-Content -LiteralPath $stdOutTmp -Raw } else { '' }
        StdErr       = if (Test-Path $stdErrTmp) { Get-Content -LiteralPath $stdErrTmp -Raw } else { '' }
        Invocations  = @(if (Test-Path $invocationsPath) { Get-Content -LiteralPath $invocationsPath } else { @() })
        StateRoot    = $stateRoot
        HistoryPath  = Join-Path $stateRoot 'history.jsonl'
        CacheDir     = Join-Path $stateRoot 'cache'
        MetricsPath  = Join-Path $stateRoot 'metrics.jsonl'
        StdInCapture = if ($captureStdinPath -and (Test-Path $captureStdinPath)) { Get-Content -LiteralPath $captureStdinPath -Raw -Encoding UTF8 } else { '' }
    }
}

function Assert-PathOrderingGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TestDrive,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    # Stage ollama.cmd, prepend, verify Get-Command resolves to the stub.
    $binDir = Join-Path $TestDrive 'gate-bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item (Join-Path $RepoRoot 'Tests/integration/ollama.cmd') (Join-Path $binDir 'ollama.cmd') -Force
    $savedPath = $env:Path
    try {
        $env:Path = "$binDir;$env:Path"
        $resolved = (Get-Command ollama -ErrorAction Stop).Source
        $expected = Join-Path $binDir 'ollama.cmd'
        if ($resolved -ne $expected) {
            throw "PATH ordering gate failed: Get-Command ollama => '$resolved', expected '$expected'. Aborting integration suite."
        }
    } finally {
        $env:Path = $savedPath
    }
}
