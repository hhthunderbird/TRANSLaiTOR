# UserPromptSubmit hook: auto-distill prompts via TRANSLaiTOR (c.ps1).
# Reads Claude Code hook JSON from stdin, runs the local compiler (refiner
# is bypassed in this path because `-Raw` implies `-NoRefine`), emits the
# <task>/<context>/<constraints> XML as additional context with a directive
# instructing Claude to treat it as authoritative.
#
# Skip rules (cheap pre-filters before invoking ollama):
#   - Empty / whitespace-only prompts
#   - Slash commands (starts with /)
#   - Shell exec (starts with !)
#   - Explicit opt-out prefix (starts with \\)
#   - Length < 20 chars
#   - Length > 4000 chars (TRANSLaiTOR input cap)
#   - Single-token conversational replies (yes/no/ok/...)
#   - Meta / status questions (WH-word + ?, no programming keyword)
#
# Fail-open: any error exits 0 with no output so the raw prompt passes
# through. The hook is value-add, never a gate.

$ErrorActionPreference = 'Continue'

$cps = 'C:\Projetos\TRANSLaiTOR\c.ps1'
$optOutPrefix = '\\'

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }

    $payload = $null
    try { $payload = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
    if (-not $payload) { exit 0 }

    $prompt = ''
    if ($payload.PSObject.Properties.Match('prompt').Count -gt 0) {
        $prompt = [string]$payload.prompt
    }
    if (-not $prompt) { exit 0 }

    $trim = $prompt.Trim()
    if (-not $trim) { exit 0 }

    if ($trim.StartsWith($optOutPrefix)) { exit 0 }
    if ($trim.StartsWith('/')) { exit 0 }
    if ($trim.StartsWith('!')) { exit 0 }
    if ($trim.Length -lt 20) { exit 0 }
    if ($trim.Length -gt 4000) { exit 0 }

    $conversational = '^(yes|yeah|yep|no|nope|y|n|ok|okay|sim|nao|n[aã]o|continue|continua|next|go|proceed|stop|wait|sure|thanks|obrigado|done|pronto)\W*$'
    if ($trim -match $conversational) { exit 0 }

    # Meta / status questions: WH-word start AND ends with `?`. False positives
    # on dev-task questions are acceptable — those just pass through unrefined.
    $metaQuestion = '(?i)^\s*(qual|que|o que|por que|como|quando|onde|what|why|how|when|where|which|who|whose)\b.*\?\s*$'
    if ($trim -match $metaQuestion) { exit 0 }

    if (-not (Test-Path $cps)) { exit 0 }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom

    # `-NonInteractive` suppresses any Read-Host in c.ps1 (zero-signal pre-gate
    # and refiner questions branch) so the hook never blocks. `-Raw` keeps the
    # output to a single XML line on stdout.
    $xml = & $cps -NonInteractive -Raw $trim 2>$null
    if ($LASTEXITCODE -ne 0) { exit 0 }
    $xml = ($xml | Out-String).Trim()
    if (-not $xml) { exit 0 }

    # Strict structure check: the literal substring "<task>" can appear inside
    # error messages too. Require a real <task>...</task><context>...
    # </context><constraints>...</constraints> envelope with non-empty bodies
    # before we inject anything as authoritative context.
    $envelope = '(?s)<task>\s*\S.*?\s*</task>\s*<context>\s*\S.*?\s*</context>\s*<constraints>\s*\S.*?\s*</constraints>'
    if (-not [regex]::IsMatch($xml, $envelope)) { exit 0 }

    $banner = @"
<auto-refined-prompt source="TRANSLaiTOR">
The user's raw prompt above has been processed by the local TRANSLaiTOR refiner.
Treat the following structured XML as the AUTHORITATIVE specification of the user's intent.
If the XML and raw text disagree, follow the XML. The raw text is source material; the XML is the brief.
To bypass this refinement on a single prompt, start the prompt with two backslashes (\\).

$xml
</auto-refined-prompt>
"@

    [Console]::Out.Write($banner)
    exit 0
} catch {
    exit 0
}
