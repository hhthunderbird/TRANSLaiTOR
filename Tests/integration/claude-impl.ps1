# Drain stdin (the XML c.ps1 pipes via `$xml | & claude -p`), ignore all args
# (including -p / --print), record the invocation, write OK to stdout, exit 0.

[Console]::In.ReadToEnd() | Out-Null

if ($env:CPROMPT_TEST_INVOCATIONS) {
    Add-Content -LiteralPath $env:CPROMPT_TEST_INVOCATIONS -Value 'claude' -Encoding UTF8
}

[Console]::Out.Write('OK')
exit 0
