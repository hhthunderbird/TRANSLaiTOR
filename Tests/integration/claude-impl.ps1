# Test stub for `claude` CLI. Drains stdin, records invocation, exits 0.
# When --output-format json is detected, emits a JSON response matching
# Claude CLI's actual output shape. When CPROMPT_TEST_CLAUDE_BAD_JSON=1,
# emits malformed output to test the fallback path.

[Console]::In.ReadToEnd() | Out-Null

if ($env:CPROMPT_TEST_INVOCATIONS) {
    Add-Content -LiteralPath $env:CPROMPT_TEST_INVOCATIONS -Value 'claude' -Encoding UTF8
}

$hasJsonFlag = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--output-format' -and ($i + 1) -lt $args.Count -and $args[$i + 1] -eq 'json') {
        $hasJsonFlag = $true
        break
    }
}

if ($hasJsonFlag) {
    if ($env:CPROMPT_TEST_CLAUDE_BAD_JSON -eq '1') {
        [Console]::Out.Write('NOT_JSON_OUTPUT')
    } else {
        $json = '{"result":"stub-claude-answer","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2},"total_cost_usd":0.001,"duration_ms":1500,"modelUsage":{"claude-sonnet-4-6":{"costUSD":0.001,"input_tokens":10,"output_tokens":5}}}'
        [Console]::Out.Write($json)
    }
} else {
    [Console]::Out.Write('OK')
}

exit 0
