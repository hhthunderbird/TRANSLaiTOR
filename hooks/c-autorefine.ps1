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
    if ($trim.Length -lt 30) { exit 0 }
    if ($trim.Length -gt 4000) { exit 0 }

    $conversational = '^(yes|yeah|yep|no|nope|y|n|ok|okay|sim|nao|n[aã]o|continue|continua|next|go|proceed|stop|wait|sure|thanks|obrigado|done|pronto)\W*$'
    if ($trim -match $conversational) { exit 0 }

    if (-not (Test-Path $cps)) { exit 0 }

    # Extract last assistant text from transcript for conversation context.
    # This lets the compiler understand mid-conversation replies like
    # "agora reavalie os Injects" by seeing what was discussed before.
    $lastAssistantText = ''
    $transcriptPath = ''
    if ($payload.PSObject.Properties.Match('transcript_path').Count -gt 0) {
        $transcriptPath = [string]$payload.transcript_path
    }
    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        try {
            $tLines = Get-Content $transcriptPath -Tail 60 -Encoding utf8
            for ($ti = $tLines.Count - 1; $ti -ge 0; $ti--) {
                $line = $tLines[$ti]
                if (-not $line) { continue }
                # Cheap pre-filter: real JSONL entries always contain the
                # substring "assistant" somewhere. Skip lines that don't, but
                # never trust the substring alone — verify $tEntry.type after
                # parse to avoid false-positives on user text quoting JSON.
                if ($line.IndexOf('assistant') -lt 0) { continue }
                $tEntry = $null
                try { $tEntry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if (-not $tEntry -or $tEntry.type -ne 'assistant') { continue }
                $textBlocks = @($tEntry.message.content | Where-Object { $_.type -eq 'text' })
                if ($textBlocks.Count -gt 0) {
                    $lastAssistantText = [string]$textBlocks[0].text
                    break
                }
            }
        } catch {}
        if ($lastAssistantText.Length -gt 500) {
            $lastAssistantText = $lastAssistantText.Substring(0, 500)
        }
    }

    # Read project CLAUDE.md for domain awareness (e.g. "this is a Unity project").
    $harnessContext = ''
    try {
        $cwd = if ($payload.PSObject.Properties.Match('cwd').Count -gt 0) { $payload.cwd } else { (Get-Location).Path }
        $claudeMd = Join-Path $cwd 'CLAUDE.md'
        if (Test-Path $claudeMd) {
            $content = Get-Content $claudeMd -Raw -Encoding utf8
            if ($content.Length -gt 500) { $content = $content.Substring(0, 500) }
            $harnessContext = "[CLAUDE.md] $content"
        }
    } catch {}

    if ($lastAssistantText -or $harnessContext) {
        $combinedContext = ($lastAssistantText, $harnessContext | Where-Object { $_ }) -join "`n"
        if ($combinedContext.Length -gt 800) {
            $combinedContext = $combinedContext.Substring(0, 800)
        }
        $lastAssistantText = $combinedContext
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom

    # `-NonInteractive` suppresses any Read-Host in c.ps1 (zero-signal pre-gate
    # and refiner questions branch) so the hook never blocks. `-Raw` keeps the
    # output to a single XML line on stdout.
    #
    # Stream redirects (all three streams must die before reaching this
    # subprocess's stdout, which CC captures as authoritative context):
    #   2>$null  error stream (ollama spinner stderr, etc).
    #   3>$null  warning stream (`Write-Warning` in c.ps1).
    #   6>$null  information stream — c.ps1 uses `Write-Host` for status and
    #            AVISO fallback messages. In a non-tty subprocess like this
    #            hook, PS routes Write-Host through powershell.exe stdout,
    #            and without this redirect those messages get injected as
    #            authoritative refinement.
    $cpsArgs = @('-NonInteractive', '-Raw', $trim)
    if ($lastAssistantText) {
        $cpsArgs = @('-NonInteractive', '-Raw', '-ConversationContext', $lastAssistantText, $trim)
    }
    $xml = & $cps @cpsArgs 2>$null 3>$null 6>$null
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
