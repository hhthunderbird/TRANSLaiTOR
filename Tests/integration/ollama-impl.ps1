# Test stub for `ollama run [--nowordwrap] <model>`. Reads stdin (discards),
# parses model from $args, increments invocation counter, writes fixture payload.
# Strict mode intentionally OFF — `@()[-1]` would throw under StrictMode Latest.

[Console]::In.ReadToEnd() | Out-Null

$filtered = @($args | Where-Object { $_ -ne 'run' -and $_ -notlike '--*' })
if ($filtered.Count -eq 0) {
    [Console]::Error.WriteLine("stub: no model arg in: $($args -join ' ')")
    exit 1
}
$model = $filtered[-1]

if ($env:CPROMPT_TEST_INVOCATIONS) {
    Add-Content -LiteralPath $env:CPROMPT_TEST_INVOCATIONS -Value $model -Encoding UTF8
}

if (-not $env:CPROMPT_TEST_FIXTURE) {
    [Console]::Error.WriteLine("stub: CPROMPT_TEST_FIXTURE not set")
    exit 1
}

$raw = Get-Content -LiteralPath $env:CPROMPT_TEST_FIXTURE -Raw -Encoding UTF8
$raw = $raw.TrimStart([char]0xFEFF)
$fixture = $raw | ConvertFrom-Json

if (-not $fixture.PSObject.Properties[$model]) {
    [Console]::Error.WriteLine("stub: model '$model' not in fixture $($env:CPROMPT_TEST_FIXTURE)")
    exit 1
}

[Console]::Out.Write([string]$fixture.$model)
exit 0
