[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Send,
    [switch]$Raw,
    [switch]$Help,
    [switch]$NoCache,
    [switch]$Last,
    [switch]$NoRefine,
    [switch]$NonInteractive,
    [switch]$Interactive,
    [switch]$MetaQuery,
    [string]$Model = 'prompt-opt',
    [string]$RefinerModel = 'prompt-refiner',
    [string]$ConversationContext = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Prompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxInputChars = 4000
$script:StateRoot     = if ($env:CPROMPT_STATE_ROOT) { $env:CPROMPT_STATE_ROOT } else { Join-Path $env:USERPROFILE '.cprompt' }
$script:CacheDir      = Join-Path $script:StateRoot 'cache'
$script:HistoryPath   = Join-Path $script:StateRoot 'history.jsonl'

function Show-Usage {
    @"
TRANSLaiTOR - local prompt compiler

uso:  c                          le clipboard, mostra preview, Enter/Esc
      c -Raw                     le clipboard direto, sem prompt
      c <ideia>                  destila e copia XML para clipboard
      c <ideia> -Raw             imprime XML em stdout (implica -NoRefine)
      c <ideia> -Send            envia XML direto para claude -p
      c <ideia> -Model X         usa modelo Ollama compilador diferente (default: prompt-opt)
      c <ideia> -RefinerModel Y  usa modelo Ollama refinador diferente (default: prompt-refiner)
      c <ideia> -NoRefine        pula o estagio refinador, vai direto ao compilador
      c <ideia> -Interactive     habilita Q&A do refiner/pre-gate (default: skip Q&A)
      c <ideia> -NonInteractive  (alias historico; agora e o default)
      c <ideia> -NoCache         ignora cache, forca chamada nova ao Ollama compilador
      c -Last                    imprime ultimo XML do historico
      c -Help                    mostra esta ajuda

cache:        chave inclui (Model + Text). Mudar -Model invalida implicitamente.
estado local: $script:StateRoot
limites:      input maximo $script:MaxInputChars caracteres
"@
}

# Force UTF-8 no-BOM end-to-end (fixes Ollama encoding conflict on Windows)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8NoBom
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

Import-Module (Join-Path $PSScriptRoot 'cprompt.psm1') -Force

if ($Help) {
    Show-Usage
    exit 0
}

if ($Last) {
    $entry = Get-LastHistoryEntry -Path $script:HistoryPath
    if (-not $entry) {
        Write-Host "ERRO: historico vazio em $script:HistoryPath." -ForegroundColor Red
        exit 7
    }
    if ($Raw) {
        Write-Output $entry.xml
    } else {
        Write-Host "ultimo entry (ts=$($entry.ts), model=$($entry.model)):" -ForegroundColor Cyan
        Write-Host "input: $($entry.input)" -ForegroundColor DarkGray
        Write-Host "`n$($entry.xml)`n" -ForegroundColor Gray
        $entry.xml | Set-Clipboard
        Write-Host "copiado p/ clipboard." -ForegroundColor Green
    }
    exit 0
}

$userInput = if ($Prompt) { ($Prompt -join ' ').Trim() } else { '' }

if (-not $userInput) {
    if ($env:CPROMPT_CLIPBOARD_OVERRIDE) {
        $clipText = if ($env:CPROMPT_TEST_CLIPBOARD) { $env:CPROMPT_TEST_CLIPBOARD } else { '' }
    } else {
        $clipText = (Get-Clipboard -Raw)
    }
    if (-not $clipText) {
        Write-Host "ERRO: clipboard vazio ou sem texto." -ForegroundColor Red
        exit 1
    }

    $clipLines = $clipText -split "`n"
    $clipChars = $clipText.Length
    $clipLineCount = $clipLines.Count
    Write-Host "[clipboard: $clipChars chars, $clipLineCount linhas]" -ForegroundColor DarkCyan

    $skipPrompt = $Raw -or [Console]::IsInputRedirected
    if (-not $skipPrompt) {
        $previewCount = [Math]::Min(5, $clipLines.Count)
        for ($i = 0; $i -lt $previewCount; $i++) {
            Write-Host "  $($clipLines[$i])" -ForegroundColor DarkGray
        }
        if ($clipLines.Count -gt 5) {
            $remaining = $clipLines.Count - 5
            Write-Host "  ...($remaining mais)" -ForegroundColor DarkGray
        }
        Write-Host "Enter=usar, Esc=cancelar" -ForegroundColor Yellow
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape') {
            Write-Host "cancelado." -ForegroundColor DarkGray
            exit 0
        }
    }

    $userInput = $clipText
}

if (-not (Test-InputAcceptable -Text $userInput -MaxLength $script:MaxInputChars)) {
    if (-not $userInput) {
        Show-Usage
        exit 1
    }
    Write-Host "ERRO: input invalido (vazio ou > $script:MaxInputChars chars)." -ForegroundColor Red
    exit 1
}

$rawInput        = $userInput
$refined         = $false
$metricMode      = 'raw'   # default: refiner not consulted
$refinerMs       = 0
$compilerMs      = 0
$contextGatherMs = 0
$xml             = $null
$fromCache       = $false
$runStart      = [System.Diagnostics.Stopwatch]::StartNew()
$refinerStats  = $null
$compilerStats = $null
$metricsPath   = Join-Path $script:StateRoot 'metrics.jsonl'

# Tri-state cache for ollama PATH lookup: $null = unchecked, $true/$false = result.
$ollamaPresent = $null

# `-Raw` implies `-NoRefine`: scripted use cannot answer prompts interactively.
$skipRefiner = $NoRefine -or $Raw

# Default: Q&A loops are OFF — refiner/pre-gate fall back to raw passthrough.
# `-Interactive` opts in to the (blocking) prompts. `-NonInteractive` kept as
# a no-op alias so older hook installs that still pass it do not break.
$askQuestions = [bool]$Interactive

# Zero-signal pre-gate: inputs with <4 words give the 3B refiner nothing to
# work with, so it hallucinates a topic. Ask ONE deterministic question
# that prompts a richer reformulation, then skip the model refiner entirely.
# Multiple questions hurt the small compiler downstream — keep it to one.
if (-not $skipRefiner -and (Test-InputIsZeroSignal -Text $userInput)) {
    if ($askQuestions) {
        Write-Host '--- input muito vago, reformule ---' -ForegroundColor DarkCyan
        $q = 'reformule em uma frase com area, problema e stack:'
        Write-Host "1) $q" -ForegroundColor Yellow
        $answer = (Read-Host '>').Trim()
        if ($answer) {
            $userInput = $answer
            $refined = $true
        }
        $metricMode = 'pregate'
        $skipRefiner = $true
    } else {
        # Default: zero-friction. Pre-gate would block on Read-Host, skip
        # to raw passthrough; downstream compiler is the next gate.
        Write-Host "(input vago - usando cru. -Interactive p/ reformular)" -ForegroundColor DarkGray
        $metricMode = 'pregate-skip'
        $skipRefiner = $true
    }
}

# Meta-query stage: detect status/conversational queries and build synthetic XML
# from project context instead of sending to the LLM compiler.
$skipCompiler = $false
if ($MetaQuery -or (Test-InputIsMetaQuery -Text $userInput)) {
    if (-not $Raw) {
        Write-Host "--- consulta de status detectada ---" -ForegroundColor DarkCyan
    }
    $contextWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetMs = if ($NonInteractive -or $Raw) { 3000 } else { 0 }
    $progressCb = if (-not $Raw) {
        { param($Step) Write-Host "  [$Step]" -ForegroundColor DarkGray }
    } else { $null }
    $projectCtx = Get-ProjectContext -Path (Get-Location).Path -BudgetMs $budgetMs -OnProgress $progressCb
    $xml = Format-MetaQueryXml -Question $userInput -Context $projectCtx
    $contextWatch.Stop()
    $contextGatherMs = [int]$contextWatch.ElapsedMilliseconds
    $metricMode = 'meta-query'
    $skipRefiner = $true
    $skipCompiler = $true
}

# Error-log stage: detect stack traces / compiler errors and extract signal
# instead of sending to the LLM compiler (which would rewrite them).
if (-not $skipCompiler -and (Test-InputIsErrorLog -Text $userInput)) {
    if (-not $Raw) {
        Write-Host "--- log de erro detectado (extraindo sinal) ---" -ForegroundColor DarkCyan
    }
    $xml = Format-ErrorLogXml -Text $userInput
    $metricMode = 'error-log'
    $skipRefiner = $true
    $skipCompiler = $true
}

if (-not $skipRefiner) {
    try { $null = Resolve-Tool 'ollama'; $ollamaPresent = $true } catch { $ollamaPresent = $false }

    if ($ollamaPresent) {
        Write-Host "--- refinando input ($RefinerModel) ---" -ForegroundColor DarkCyan

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $refinerRaw = ''
        $refinerWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $tickCb = if (-not $Raw) { New-OllamaTickCallback -Watch $refinerWatch } else { $null }
        try {
            $refinerResult = Invoke-OllamaModel -Text $userInput -Model $RefinerModel -CaptureStats -OnTick $tickCb
            $refinerRaw    = [string]$refinerResult.Text
            $refinerStats  = $refinerResult.Stats
        } catch {
            $refinerRaw = ''
        }
        $refinerWatch.Stop()
        $refinerMs = [int]$refinerWatch.ElapsedMilliseconds
        if (-not $Raw) { Write-Host "`r  done (${refinerMs}ms)       " -ForegroundColor DarkGray }
        $ErrorActionPreference = $prevEAP

        $parsed = $null
        if ($refinerRaw -and $LASTEXITCODE -eq 0) {
            $parsed = Get-RefinerOutput $refinerRaw
        }

        if (Test-RefinerOutput $parsed) {
            if ($parsed.Mode -eq 'questions') {
                if ($askQuestions) {
                    $metricMode = 'questions'
                    # Cap at the FIRST question only. The 3B compiler downstream
                    # cannot benefit from multi-Q context — extra questions just
                    # add noise. Modelfile.refiner is also tuned to emit one.
                    $firstQ = $parsed.Payload[0]
                    Write-Host "1) $firstQ" -ForegroundColor Yellow
                    $answer = Read-Host '>'
                    $pairs = @(@{ Question = $firstQ; Answer = $answer })
                    $userInput = Merge-RefinementAnswers -Raw $rawInput -Pairs $pairs
                    if ($userInput -ne $rawInput) { $refined = $true }
                } else {
                    # Default: zero-friction. Refiner wants Q&A but we skip.
                    Write-Host "(refiner pediu Q&A - usando cru. -Interactive p/ responder)" -ForegroundColor DarkGray
                    $metricMode = 'questions-skip'
                }
            } else {
                # Mode = 'passthrough' → leave $userInput alone, $refined stays $false.
                $metricMode = 'passthrough'
            }
        } else {
            # Refiner failed or returned garbage. Fall back to raw.
            $metricMode = 'skip'
            Write-Host "(refiner sem saida util - usando input cru)" -ForegroundColor DarkGray
        }
    } else {
        $metricMode = 'skip'
    }
}

if (-not $skipCompiler) {
    $cacheKey = Get-CacheKey -Model $Model -Text $userInput -Context $ConversationContext

    if (-not $NoCache) {
        $cached = Get-CachedXml -Key $cacheKey -CacheDir $script:CacheDir
        if ($cached) {
            $xml = $cached
            $fromCache = $true
            $metricMode = 'cache'
            if (-not $Raw) {
                Write-Host "--- cache hit ($Model) ---" -ForegroundColor DarkGreen
            }
        }
    }

    if (-not $xml) {
        if ($null -eq $ollamaPresent) {
            try { $null = Resolve-Tool 'ollama'; $ollamaPresent = $true } catch { $ollamaPresent = $false }
        }
        if (-not $ollamaPresent) {
            Write-Host "ERRO: ollama nao encontrado no PATH." -ForegroundColor Red
            exit 2
        }

        if (-not $Raw) {
            Write-Host "--- destilando prompt local ($Model) ---" -ForegroundColor Cyan
        }

        # Pipe stdin to ollama. Suppress spinner stderr (TTY escapes). Don't let
        # native-cmd stderr trip $ErrorActionPreference=Stop.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $ollamaOutput = ''
        $compilerWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $compilerInput = $userInput
        if ($ConversationContext) {
            $compilerInput = "[CONTEXTO DA CONVERSA]`n$ConversationContext`n[PROMPT DO USUÁRIO]`n$userInput"
        }
        $tickCb = if (-not $Raw) { New-OllamaTickCallback -Watch $compilerWatch } else { $null }
        try {
            $compilerResult = Invoke-OllamaModel -Text $compilerInput -Model $Model -CaptureStats -OnTick $tickCb
            $ollamaOutput   = [string]$compilerResult.Text
            $compilerStats  = $compilerResult.Stats
        } catch {
            $compilerWatch.Stop()
            $ErrorActionPreference = $prevEAP
            Write-Host "ERRO: falha ao executar ollama: $($_.Exception.Message)" -ForegroundColor Red
            exit 4
        }
        $compilerWatch.Stop()
        $compilerMs = [int]$compilerWatch.ElapsedMilliseconds
        if (-not $Raw) { Write-Host "`r  done (${compilerMs}ms)       " -ForegroundColor DarkGray }
        $ErrorActionPreference = $prevEAP

        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERRO: ollama saiu com codigo $LASTEXITCODE." -ForegroundColor Red
            Write-Host $ollamaOutput -ForegroundColor DarkGray
            exit 5
        }

        $xmlCandidate = Get-PromptXml $ollamaOutput
        $resolved = Resolve-CompilerFallback -Xml $xmlCandidate -RawInput $rawInput
        $xml = $resolved.Xml
        if ($resolved.IsFallback) {
            Write-Host "AVISO: otimizador nao produziu XML valido. Passando texto cru sem destilacao." -ForegroundColor Yellow
            Write-Host "--- saida bruta do otimizador (descartada) ---" -ForegroundColor DarkGray
            Write-Host $ollamaOutput -ForegroundColor DarkGray
            $metricMode = 'fallback'
            # Do not cache the fallback — a future retry may produce real XML.
        } elseif (-not $NoCache) {
            Set-CachedXml -Key $cacheKey -Xml $xml -CacheDir $script:CacheDir
        }
    }
} # end skipCompiler guard

# Always record to history (cache hits included, so -Last shows recent context)
Add-HistoryEntry -Path $script:HistoryPath -Entry @{
    rawInput = $rawInput
    input    = $userInput
    model    = $Model
    xml      = $xml
    cached   = $fromCache
    refined  = $refined
}

$runStart.Stop()
try {
    $xmlLen = if ($xml) { $xml.Length } else { 0 }
    $entry = @{
        model         = $Model
        refinerModel  = $RefinerModel
        mode          = $metricMode
        inputChars    = $rawInput.Length
        refinedChars  = $userInput.Length
        xmlChars      = $xmlLen
        refinerMs     = $refinerMs
        compilerMs    = $compilerMs
        contextGatherMs = $contextGatherMs
        totalMs       = [int]$runStart.ElapsedMilliseconds
        cacheHit      = [bool]$fromCache
        flags         = @{
            Raw      = [bool]$Raw
            NoRefine = [bool]$NoRefine
            Send     = [bool]$Send
        }
    }
    # Opt-in eval-stats keys: present only when Invoke-OllamaModel actually
    # captured non-null stats. Absent on cache hits (compiler skipped) and on
    # -NoRefine / refiner-bypassed runs.
    if ($refinerStats)  { $entry.refinerEval  = $refinerStats }
    if ($compilerStats) { $entry.compilerEval = $compilerStats }
    if (-not $Send) {
        Add-MetricEntry -Path $metricsPath -Entry $entry
    }
} catch {
    # Metrics is best-effort. Never break the user-facing run.
}

if ($Raw) {
    Write-Output $xml
    exit 0
}

Write-Host "`n$xml`n" -ForegroundColor Gray

if ($Send) {
    if (-not (Test-CommandPresent -Name 'claude')) {
        Write-Host "ERRO: 'claude' CLI nao encontrado no PATH. XML copiado para clipboard como fallback." -ForegroundColor Red
        $xml | Set-Clipboard
        if ($null -ne $entry) {
            try { Add-MetricEntry -Path $metricsPath -Entry $entry } catch {}
        }
        exit 8
    }
    Write-Host "--- enviando para claude CLI ---" -ForegroundColor Cyan
    $claudeRaw  = $xml | & claude -p --output-format json
    $claudeExit = $LASTEXITCODE
    $claudeUsage = $null
    try {
        $claudeObj  = $claudeRaw | ConvertFrom-Json
        $claudeText = $claudeObj.result
        $claudeUsage = @{
            inputTokens         = [int]$claudeObj.usage.input_tokens
            outputTokens        = [int]$claudeObj.usage.output_tokens
            cacheReadTokens     = [int]$claudeObj.usage.cache_read_input_tokens
            cacheCreationTokens = [int]$claudeObj.usage.cache_creation_input_tokens
            costUsd             = [double]$claudeObj.total_cost_usd
            durationMs          = [int]$claudeObj.duration_ms
            model               = @($claudeObj.modelUsage.PSObject.Properties)[0].Name
        }
    } catch {
        $claudeText  = $claudeRaw
        $claudeUsage = $null
        Write-Warning "Could not parse Claude JSON output; token usage not captured."
    }
    if ($null -ne $entry) {
        if ($claudeUsage) { $entry.claudeUsage = $claudeUsage }
        try { Add-MetricEntry -Path $metricsPath -Entry $entry } catch {}
    }
    Write-Output $claudeText
    exit $claudeExit
} else {
    $xml | Set-Clipboard
    Write-Host "copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude." -ForegroundColor Green
}
