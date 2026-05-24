Set-StrictMode -Version Latest

function Remove-Bom {
    [CmdletBinding()]
    param([string]$Text)
    if (-not $Text) { return '' }
    $bom = [char]0xFEFF
    if ($Text.Length -gt 0 -and $Text[0] -eq $bom) {
        return $Text.Substring(1)
    }
    return $Text
}

function Remove-AnsiEscapes {
    [CmdletBinding()]
    param([string]$Text)
    if (-not $Text) { return '' }
    # Strip ANSI/CSI escape sequences (cursor moves, erase commands, color codes)
    # that `ollama run` injects for terminal word-wrap. Without this, captured
    # stdout interleaves visual rewinds into `<q>`/`<task>` bodies.
    return [regex]::Replace($Text, "`e\[[0-9;]*[A-Za-z]", '')
}

function ConvertFrom-OllamaVerboseStats {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $stats = @{}

    # Duration helper: float + unit -> int ms.
    $toMs = {
        param($value, $unit)
        $n = [double]$value
        switch ($unit.ToLowerInvariant()) {
            'ms' { return [int][math]::Round($n) }
            's'  { return [int][math]::Round($n * 1000.0) }
            default { return $null }
        }
    }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    $m = [regex]::Match($Text, 'prompt\s+eval\s+count:\s*(\d+)\s*token', $opts)
    if ($m.Success) { $stats.promptEvalCount = [int]$m.Groups[1].Value }

    $m = [regex]::Match($Text, 'prompt\s+eval\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.promptEvalDurationMs = $ms }
    }

    # The 'eval count' regex must NOT match 'prompt eval count' — anchor on word boundary.
    $m = [regex]::Match($Text, '(?<!prompt\s)\beval\s+count:\s*(\d+)\s*token', $opts)
    if ($m.Success) { $stats.evalCount = [int]$m.Groups[1].Value }

    $m = [regex]::Match($Text, '(?<!prompt\s)\beval\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.evalDurationMs = $ms }
    }

    $m = [regex]::Match($Text, 'eval\s+rate:\s*([\d.]+)\s*tokens?/s', $opts)
    if ($m.Success) { $stats.evalRate = [double]$m.Groups[1].Value }

    $m = [regex]::Match($Text, 'load\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.loadDurationMs = $ms }
    }

    $m = [regex]::Match($Text, 'total\s+duration:\s*([\d.]+)(ms|s)\b', $opts)
    if ($m.Success) {
        $ms = & $toMs $m.Groups[1].Value $m.Groups[2].Value
        if ($null -ne $ms) { $stats.totalDurationMs = $ms }
    }

    if ($stats.Count -eq 0) { return $null }
    return $stats
}

function Get-PromptXml {
    [CmdletBinding()]
    param([string]$RawOutput)
    if (-not $RawOutput) { return $null }
    $clean = Remove-Bom $RawOutput
    $clean = Remove-AnsiEscapes $clean

    function _extractTag {
        param([string]$Src, [string]$Tag)
        # Capture content from <Tag> up to first of:
        #   - any closing tag  </word>   (handles hallucinated close-tag names)
        #   - lookahead at any open tag  <word>   (handles missing close + next section)
        #   - end of string  $          (handles missing close at EOF)
        $pattern = "(?s)<$Tag>(.*?)(?:</\w+>|(?=<\w+>)|`$)"
        $m = [regex]::Match($Src, $pattern)
        if (-not $m.Success) { return $null }
        return $m.Groups[1].Value.Trim()
    }

    $task        = _extractTag $clean 'task'
    $context     = _extractTag $clean 'context'
    $constraints = _extractTag $clean 'constraints'

    if (-not $task -or -not $context -or -not $constraints) { return $null }
    return "<task>$task</task><context>$context</context><constraints>$constraints</constraints>"
}

function Test-PromptXml {
    [CmdletBinding()]
    param([string]$Xml)
    if (-not $Xml) { return $false }
    $pattern = '(?s)<task>\s*(\S.*?)\s*</task>\s*<context>\s*(\S.*?)\s*</context>\s*<constraints>\s*(\S.*?)\s*</constraints>'
    return [regex]::IsMatch($Xml, $pattern)
}

function Resolve-CompilerFallback {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Xml,
        [Parameter(Mandatory)][string]$RawInput
    )
    if (Test-PromptXml -Xml $Xml) {
        return [pscustomobject]@{ Xml = $Xml; IsFallback = $false }
    }
    return [pscustomobject]@{ Xml = $RawInput; IsFallback = $true }
}

function Resolve-Tool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Tool '$Name' not found in PATH."
    }
    return $cmd
}

function Test-CommandPresent {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-OllamaModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Model,
        [switch]$CaptureStats
    )

    if (-not $CaptureStats) {
        # Legacy path. `2>$null` swallows the terminal progress spinner ollama
        # prints to stderr. `--nowordwrap` keeps tag bodies on one logical line;
        # ANSI escapes are still cleaned downstream by Remove-AnsiEscapes /
        # Get-RefinerOutput.
        return ($Text | & ollama run --nowordwrap $Model 2>$null | Out-String)
    }

    # Stats path. Use System.Diagnostics.Process so stderr is captured raw —
    # PS 5.1 wraps native stderr as NativeCommandError records when redirected
    # via `2>$file`, which pollutes the bytes we need to regex-parse.
    $cmd = Get-Command 'ollama' -ErrorAction Stop
    $source = $cmd.Source

    # Defensive double-quote escaping for embedding into cmd.exe argument strings.
    $sourceQuoted = '"' + ($source -replace '"', '""') + '"'
    $modelQuoted  = '"' + ($Model  -replace '"', '""') + '"'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $isShim = $source -match '\.(cmd|bat)$'
    if ($isShim) {
        # CreateProcess can't exec .cmd directly; route through cmd.exe.
        # cmd.exe /c strips the first and last quote when >2 quotes are present;
        # wrap the whole command in an extra outer pair so the inner quotes survive.
        $psi.FileName  = "$env:SystemRoot\System32\cmd.exe"
        $psi.Arguments = '/c "' + $sourceQuoted + ' run --verbose --nowordwrap ' + $modelQuoted + '"'
    } else {
        $psi.FileName  = $source
        $psi.Arguments = 'run --verbose --nowordwrap ' + $modelQuoted
    }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        # Async stdout/stderr reads avoid deadlock if either stream fills its
        # pipe buffer before WaitForExit. Stdin is written then closed.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $p.StandardInput.Write($Text)
        $p.StandardInput.Close()

        $p.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()

        # Propagate ollama exit code to $LASTEXITCODE for callers that check it.
        $global:LASTEXITCODE = $p.ExitCode
    } finally {
        if ($p) { $p.Dispose() }
    }

    $statsText = Remove-AnsiEscapes -Text $stderr
    $stats = ConvertFrom-OllamaVerboseStats -Text $statsText

    return [pscustomobject]@{ Text = $stdout; Stats = $stats }
}

function Get-CacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Text
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Model`0$Text")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-CachedXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$CacheDir
    )
    $file = Join-Path $CacheDir "$Key.xml"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
}

function Set-CachedXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Xml,
        [Parameter(Mandatory)][string]$CacheDir
    )
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    $file = Join-Path $CacheDir "$Key.xml"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file, $Xml, $utf8NoBom)
}

function Add-HistoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entry
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $Entry.ContainsKey('ts')) {
        $Entry['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $line = ConvertTo-Json -InputObject $Entry -Compress -Depth 4
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-LastHistoryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return $null }
    return ($lines[-1] | ConvertFrom-Json)
}

function Add-MetricEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entry
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $Entry.ContainsKey('ts')) {
        $Entry['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $line = ConvertTo-Json -InputObject $Entry -Compress -Depth 6
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Read-MetricsFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $entries = @()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entries += ($line | ConvertFrom-Json)
        } catch {
            # Skip lines that fail to parse — partial writes, corruption, etc.
        }
    }
    return $entries
}

function Get-MetricsSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries
    )

    $hasField = {
        param($obj, $name)
        if ($obj -is [hashtable]) { return $obj.ContainsKey($name) }
        return $null -ne $obj.PSObject.Properties[$name]
    }

    $summary = [ordered]@{
        Count               = $Entries.Count
        CacheHitRate        = 0.0
        LatencyP50          = 0
        LatencyP95          = 0
        AvgCompressionRatio = 0.0
        ModeCounts          = @{}
        CompilerEvalRateP50    = 0
        CompilerEvalRateP95    = 0
        CompilerEvalCountMedian = 0
        ColdStartCount         = 0
        ColdStartRate          = 0.0
        ClaudeSendCount        = 0
        ClaudeCostTotal        = 0.0
        ClaudeCostAvg          = 0.0
        ClaudeAvgInputTokens   = 0
        ClaudeAvgOutputTokens  = 0
    }

    if ($Entries.Count -eq 0) { return [pscustomobject]$summary }

    # Cache hit rate.
    $cacheHits = @($Entries | Where-Object {
        (& $hasField $_ 'mode') -and $_.mode -eq 'cache'
    }).Count
    $summary.CacheHitRate = [math]::Round($cacheHits / $Entries.Count, 4)

    # Mode counts.
    $modeCounts = @{}
    foreach ($e in $Entries) {
        $m = if (& $hasField $e 'mode') { [string]$e.mode } else { '' }
        if (-not $m) { $m = 'unknown' }
        if (-not $modeCounts.ContainsKey($m)) { $modeCounts[$m] = 0 }
        $modeCounts[$m] = $modeCounts[$m] + 1
    }
    $summary.ModeCounts = $modeCounts

    # Latency percentiles over totalMs.
    $latencies = @($Entries |
        Where-Object { & $hasField $_ 'totalMs' } |
        ForEach-Object { [int]$_.totalMs } |
        Sort-Object)
    if ($latencies.Count -gt 0) {
        $summary.LatencyP50 = $latencies[[math]::Max(0, [math]::Ceiling(0.50 * $latencies.Count) - 1)]
        $summary.LatencyP95 = $latencies[[math]::Max(0, [math]::Ceiling(0.95 * $latencies.Count) - 1)]
    }

    # Average compression ratio (xmlChars / inputChars) over entries with both > 0.
    $ratios = @($Entries |
        Where-Object {
            (& $hasField $_ 'inputChars') -and [int]$_.inputChars -gt 0 -and (& $hasField $_ 'xmlChars')
        } |
        ForEach-Object { [double]$_.xmlChars / [double]$_.inputChars })
    if ($ratios.Count -gt 0) {
        $sum = 0.0
        foreach ($r in $ratios) { $sum += $r }
        $summary.AvgCompressionRatio = [math]::Round($sum / $ratios.Count, 4)
    }

    # Compiler eval stats — present only on entries that captured them.
    $getCompilerEval = {
        param($e)
        $hasIt = & $hasField $e 'compilerEval'
        if (-not $hasIt) { return $null }
        return $e.compilerEval
    }

    $rates = @($Entries |
        ForEach-Object { & $getCompilerEval $_ } |
        Where-Object { $_ -and (& $hasField $_ 'evalRate') } |
        ForEach-Object { [double]$_.evalRate } |
        Sort-Object)
    if ($rates.Count -gt 0) {
        $summary.CompilerEvalRateP50 = $rates[[math]::Max(0, [math]::Ceiling(0.50 * $rates.Count) - 1)]
        $summary.CompilerEvalRateP95 = $rates[[math]::Max(0, [math]::Ceiling(0.95 * $rates.Count) - 1)]
    }

    $counts = @($Entries |
        ForEach-Object { & $getCompilerEval $_ } |
        Where-Object { $_ -and (& $hasField $_ 'evalCount') } |
        ForEach-Object { [int]$_.evalCount } |
        Sort-Object)
    if ($counts.Count -gt 0) {
        $summary.CompilerEvalCountMedian = $counts[[math]::Max(0, [math]::Ceiling(0.50 * $counts.Count) - 1)]
    }

    $coldCount = 0
    foreach ($e in $Entries) {
        $isCold = $false
        foreach ($evalKey in @('compilerEval', 'refinerEval')) {
            if (& $hasField $e $evalKey) {
                $evalObj = $e.$evalKey
                if ((& $hasField $evalObj 'loadDurationMs') -and [int]$evalObj.loadDurationMs -gt 500) {
                    $isCold = $true
                    break
                }
            }
        }
        if ($isCold) { $coldCount++ }
    }
    $summary.ColdStartCount = $coldCount
    if ($Entries.Count -gt 0) {
        $summary.ColdStartRate = [math]::Round($coldCount / $Entries.Count, 4)
    }

    $claudeEntries = @($Entries | Where-Object { & $hasField $_ 'claudeUsage' })
    if ($claudeEntries.Count -gt 0) {
        $summary.ClaudeSendCount = $claudeEntries.Count
        $costSum   = 0.0
        $inputSum  = 0
        $outputSum = 0
        foreach ($ce in $claudeEntries) {
            $cu = $ce.claudeUsage
            if (& $hasField $cu 'costUsd')      { $costSum   += [double]$cu.costUsd }
            if (& $hasField $cu 'inputTokens')   { $inputSum  += [int]$cu.inputTokens }
            if (& $hasField $cu 'outputTokens')  { $outputSum += [int]$cu.outputTokens }
        }
        $summary.ClaudeCostTotal       = [math]::Round($costSum, 6)
        $summary.ClaudeCostAvg         = [math]::Round($costSum / $claudeEntries.Count, 6)
        $summary.ClaudeAvgInputTokens  = [int][math]::Round($inputSum / $claudeEntries.Count)
        $summary.ClaudeAvgOutputTokens = [int][math]::Round($outputSum / $claudeEntries.Count)
    }

    return [pscustomobject]$summary
}

function ConvertTo-SinceDate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $Value = $Value.Trim()

    if ($Value -match '^\d+([hdw])$') {
        $num = [int]($Value -replace '[hdw]$','')
        switch ($Matches[1]) {
            'h' { return [datetime]::Now.AddHours(-$num) }
            'd' { return [datetime]::Now.AddDays(-$num) }
            'w' { return [datetime]::Now.AddDays(-$num * 7) }
        }
    }

    try {
        return [datetime]::Parse($Value)
    } catch {
        Write-Error "Invalid -Since value: '$Value'. Use relative (7d, 24h, 1w) or ISO-8601 (2026-05-01)."
        return $null
    }
}

function Test-InputAcceptable {
    [CmdletBinding()]
    param(
        [string]$Text,
        [Parameter(Mandatory)][int]$MaxLength
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text.Length -gt $MaxLength) { return $false }
    return $true
}

function Test-InputIsZeroSignal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [int]$MinWords = 4
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $words = @(($Text.Trim() -split '\s+') | Where-Object { $_ })
    return ($words.Count -lt $MinWords)
}

function Test-InputIsMetaQuery {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $whWord      = '(qual|que|o que|por que|como|quando|onde|what|why|how|when|where|which|who|whose)'
    $stateMarker = '(agora|falta|pr[oó]ximo|pendente|restante|now|left|next|current|todo|remaining|status|progress)'
    $pattern     = "(?i)^\s*$whWord\b.*\b$stateMarker\b.*\?\s*$"
    return [bool]($Text -match $pattern)
}

function Format-MetaQueryXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $parts = @()
    if ($Context.Branch) { $parts += "Branch: $($Context.Branch)" }
    if ($Context.Status) {
        $statusLines = @(($Context.Status -split "`n") | Where-Object { $_.Trim() })
        $parts += "Modified: $($statusLines.Count) file(s)"
        $parts += "Files: $($Context.Status.Trim())"
    }
    if ($Context.Log) {
        $logLines = @(($Context.Log -split "`n") | Where-Object { $_.Trim() })
        $parts += "Recent: $($logLines -join ' | ')"
    }
    if ($Context.Todos) {
        $todoLines = @(($Context.Todos -split "`n") | Where-Object { $_.Trim() })
        $parts += "TODOs: $($todoLines.Count) item(s) -- $($Context.Todos.Trim())"
    }
    $pfKeys = @()
    if ($Context.ProjectFiles -and $Context.ProjectFiles.Count -gt 0) {
        foreach ($k in $Context.ProjectFiles.Keys) { $pfKeys += $k }
        $parts += "Project files: $($pfKeys -join ', ')"
    }

    $contextBody = $parts -join ' | '
    if (-not $contextBody) { $contextBody = 'No project context available' }

    $task = 'Responder consulta de status do projeto'
    $constraints = "Responder a pergunta do usuario: $Question | Listar trabalho pendente, estado atual do repositorio, proximos passos"

    return "<task>$task</task><context>$contextBody</context><constraints>$constraints</constraints>"
}

function Get-RefinerOutput {
    [CmdletBinding()]
    param([string]$RawOutput)
    if (-not $RawOutput) { return $null }
    $clean = Remove-Bom $RawOutput
    $clean = Remove-AnsiEscapes $clean

    $passthrough = [regex]::Match($clean, '(?s)<passthrough>(.*?)</\w+>')
    if (-not $passthrough.Success) {
        # `</passthrough>` is an Ollama stop token in Modelfile.refiner, so it
        # never appears in raw output. Capture to end-of-string instead.
        $passthrough = [regex]::Match($clean, '(?s)<passthrough>(.*)$')
    }
    if ($passthrough.Success) {
        $payload = $passthrough.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($payload)) { return $null }
        return @{ Mode = 'passthrough'; Payload = $payload }
    }

    $questionsBlock = [regex]::Match($clean, '(?s)<questions>(.*?)</questions>')
    if (-not $questionsBlock.Success) {
        # `</questions>` is an Ollama stop token; capture to EOF so inner <q>
        # parsing can find the close tags that actually were emitted.
        $questionsBlock = [regex]::Match($clean, '(?s)<questions>(.*)$')
    }
    if ($questionsBlock.Success) {
        $inner = $questionsBlock.Groups[1].Value
        $qMatches = [regex]::Matches($inner, '(?s)<q>(.*?)</\w+>')
        $qs = @()
        foreach ($qm in $qMatches) {
            $text = $qm.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $qs += $text
            }
        }
        if ($qs.Count -eq 0) { return $null }
        if ($qs.Count -gt 3) { $qs = $qs[0..2] }
        return @{ Mode = 'questions'; Payload = $qs }
    }

    return $null
}

function Test-RefinerOutput {
    [CmdletBinding()]
    param($Parsed)
    if ($null -eq $Parsed) { return $false }
    if ($Parsed -isnot [hashtable]) { return $false }
    if (-not $Parsed.ContainsKey('Mode')) { return $false }
    if (-not $Parsed.ContainsKey('Payload')) { return $false }
    switch ($Parsed.Mode) {
        'passthrough' {
            return -not [string]::IsNullOrWhiteSpace([string]$Parsed.Payload)
        }
        'questions' {
            return ($Parsed.Payload -is [array]) -and ($Parsed.Payload.Count -gt 0)
        }
        default { return $false }
    }
}

function Merge-RefinementAnswers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Pairs
    )
    $kept = @()
    foreach ($pair in $Pairs) {
        $answer = [string]$pair.Answer
        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            $kept += "$($pair.Question): $($answer.Trim())"
        }
    }
    if ($kept.Count -eq 0) { return $Raw }
    return "$Raw`n`n" + ($kept -join "`n")
}

function Get-RefinerRegressions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $BaselineCases,
        [Parameter(Mandatory)] [hashtable]$FreshDistributions,
        [double]$DropThreshold = 0.40
    )

    $failures = @()
    foreach ($case in $BaselineCases) {
        $expected = [string]$case.expectedMode
        if ($expected -eq 'rejected') { continue }

        $baseTrials = [int]$case.trials
        if ($baseTrials -le 0) { continue }

        $modeProp = $case.modeCounts.PSObject.Properties[$expected]
        $baseHits = if ($modeProp) { [int]$modeProp.Value } else { 0 }
        $baseRate = $baseHits / $baseTrials

        if (-not $FreshDistributions.ContainsKey($case.id)) {
            $failures += [pscustomobject]@{
                id           = [string]$case.id
                reason       = 'fresh distribution missing'
                baselineRate = $baseRate
                freshRate    = $null
                drop         = $null
            }
            continue
        }

        $fresh = @($FreshDistributions[$case.id])
        if ($fresh.Count -le 0) {
            $failures += [pscustomobject]@{
                id           = [string]$case.id
                reason       = 'fresh distribution empty'
                baselineRate = $baseRate
                freshRate    = $null
                drop         = $null
            }
            continue
        }

        $freshHits = @($fresh | Where-Object { [string]$_.Mode -eq $expected }).Count
        $freshRate = $freshHits / $fresh.Count
        $drop      = $baseRate - $freshRate

        if ($drop -gt $DropThreshold) {
            $failures += [pscustomobject]@{
                id           = [string]$case.id
                reason       = ("drop {0:P0} exceeds threshold {1:P0}" -f $drop, $DropThreshold)
                baselineRate = $baseRate
                freshRate    = $freshRate
                drop         = $drop
            }
        }
    }
    return $failures
}

Export-ModuleMember -Function `
    Remove-Bom, `
    Remove-AnsiEscapes, `
    ConvertFrom-OllamaVerboseStats, `
    ConvertTo-SinceDate, `
    Get-PromptXml, `
    Test-PromptXml, `
    Resolve-CompilerFallback, `
    Resolve-Tool, `
    Test-CommandPresent, `
    Invoke-OllamaModel, `
    Test-InputAcceptable, `
    Test-InputIsZeroSignal, `
    Test-InputIsMetaQuery, `
    Format-MetaQueryXml, `
    Get-CacheKey, `
    Get-CachedXml, `
    Set-CachedXml, `
    Add-HistoryEntry, `
    Get-LastHistoryEntry, `
    Add-MetricEntry, `
    Read-MetricsFile, `
    Get-MetricsSummary, `
    Get-RefinerOutput, `
    Test-RefinerOutput, `
    Merge-RefinementAnswers, `
    Get-RefinerRegressions
