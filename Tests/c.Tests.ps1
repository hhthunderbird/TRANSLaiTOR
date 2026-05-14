$here = Split-Path -Parent $MyInvocation.MyCommand.Path
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
        $stdout = & powershell.exe @psArgs 2>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        $env:USERPROFILE = $prevHome
        $env:PATH = $prevPath
    }

    return [pscustomobject]@{ ExitCode = $exit; StdOut = $stdout }
}

Describe 'c.ps1 -Help' {
    It 'exits 0 and prints the usage banner' {
        $tmpHome = Join-Path $TestDrive 'home-help'
        $res = Invoke-CScript -Args @('-Help') -IsolatedHome $tmpHome
        $res.ExitCode | Should Be 0
        $res.StdOut   | Should Match 'TRANSLaiTOR'
        $res.StdOut   | Should Match 'uso:'
    }
}

Describe 'c.ps1 with no prompt' {
    It 'exits 1 and shows usage when no positional prompt is supplied' {
        $tmpHome = Join-Path $TestDrive 'home-noprompt'
        $res = Invoke-CScript -Args @() -IsolatedHome $tmpHome
        $res.ExitCode | Should Be 1
        $res.StdOut   | Should Match 'TRANSLaiTOR'
    }
}

Describe 'c.ps1 input validation' {
    It 'exits 1 on input that exceeds MaxInputChars (4000)' {
        $tmpHome = Join-Path $TestDrive 'home-oversize'
        $oversized = 'x' * 5000
        $res = Invoke-CScript -Args @($oversized) -IsolatedHome $tmpHome
        $res.ExitCode | Should Be 1
        $res.StdOut   | Should Match '(?i)invalido'
    }
}

Describe 'c.ps1 -Last' {
    It 'exits 7 with "historico vazio" when no history exists' {
        $tmpHome = Join-Path $TestDrive 'home-emptyhist'
        $res = Invoke-CScript -Args @('-Last') -IsolatedHome $tmpHome
        $res.ExitCode | Should Be 7
        $res.StdOut   | Should Match '(?i)historico vazio'
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
        $res.ExitCode | Should Be 0
        $res.StdOut   | Should Match '<task>R</task>'
        $res.StdOut   | Should Match '<constraints>T</constraints>'
    }
}
