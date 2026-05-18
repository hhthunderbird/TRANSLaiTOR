BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:hookSource = Join-Path $script:repoRoot 'hooks/c-autorefine.ps1'

    function Invoke-HookSubprocess {
        param(
            [Parameter(Mandatory)][string]$TestDrive,
            [Parameter(Mandatory)][string]$Prompt,
            [Parameter(Mandatory)][string]$StubBody
        )

        $stubPath = Join-Path $TestDrive 'cps-stub.ps1'
        Set-Content -LiteralPath $stubPath -Value $StubBody -Encoding UTF8

        $hookText = Get-Content -LiteralPath $script:hookSource -Raw
        $escaped  = $stubPath.Replace("'", "''")
        $patched  = [regex]::Replace($hookText, "(?m)^\s*\`$cps\s*=\s*'[^']*'", "`$cps = '$escaped'")
        if ($patched -eq $hookText) {
            throw "Failed to rewrite `$cps line in hook source — regex did not match."
        }
        $hookCopy = Join-Path $TestDrive 'c-autorefine-test.ps1'
        Set-Content -LiteralPath $hookCopy -Value $patched -Encoding UTF8

        $stdInTmp  = Join-Path $TestDrive 'stdin.json'
        $stdOutTmp = Join-Path $TestDrive 'stdout.txt'
        $stdErrTmp = Join-Path $TestDrive 'stderr.txt'
        $payload = (@{ prompt = $Prompt } | ConvertTo-Json -Compress)
        Set-Content -LiteralPath $stdInTmp -Value $payload -Encoding UTF8 -NoNewline

        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hookCopy)
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
            -RedirectStandardInput $stdInTmp `
            -RedirectStandardOutput $stdOutTmp `
            -RedirectStandardError $stdErrTmp `
            -Wait -PassThru -NoNewWindow

        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            StdOut   = if (Test-Path $stdOutTmp) { Get-Content -LiteralPath $stdOutTmp -Raw } else { '' }
            StdErr   = if (Test-Path $stdErrTmp) { Get-Content -LiteralPath $stdErrTmp -Raw } else { '' }
        }
    }
}

Describe 'c-autorefine.ps1 stream isolation' {
    It 'emits only the envelope on stdout when c.ps1 writes to information/warning/error streams' {
        $stub = @'
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$Raw,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
Write-Host 'AVISO: status leak that must not appear in hook stdout'
Write-Warning 'warn leak that must not appear in hook stdout'
Write-Error  'err leak that must not appear in hook stdout' -ErrorAction Continue
'<task>refined task</task><context>refined context</context><constraints>refined constraints</constraints>'
exit 0
'@
        $r = Invoke-HookSubprocess `
            -TestDrive $TestDrive `
            -Prompt 'implementa cache lru thread-safe em go com ttl 60s' `
            -StubBody $stub

        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Match '<task>refined task</task>'
        $r.StdOut   | Should -Not -Match 'AVISO'
        $r.StdOut   | Should -Not -Match 'warn leak'
        $r.StdOut   | Should -Not -Match 'err leak'
    }

    It 'suppresses raw stub stdout when envelope is malformed (no leak via banner)' {
        $stub = @'
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$Raw,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
Write-Host 'AVISO: compiler errored, falling back to passthrough'
'this is not an XML envelope, just prose that should be filtered out'
exit 0
'@
        $r = Invoke-HookSubprocess `
            -TestDrive $TestDrive `
            -Prompt 'implementa cache lru thread-safe em go com ttl 60s' `
            -StubBody $stub

        $r.ExitCode | Should -Be 0
        $r.StdOut   | Should -Not -Match 'AVISO'
        $r.StdOut   | Should -Not -Match 'auto-refined-prompt'
    }
}
