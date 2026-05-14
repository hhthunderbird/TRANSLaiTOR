[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Send,
    [switch]$Raw,
    [switch]$Help,
    [switch]$NoCache,
    [switch]$Last,
    [switch]$NoRefine,
    [string]$Model = 'prompt-opt',
    [string]$RefinerModel = 'prompt-refiner',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Prompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxInputChars = 4000
$script:StateRoot     = Join-Path $env:USERPROFILE '.cprompt'
$script:CacheDir      = Join-Path $script:StateRoot 'cache'
$script:HistoryPath   = Join-Path $script:StateRoot 'history.jsonl'

function Show-Usage {
    @"
TRANSLaiTOR - local prompt compiler

uso:  c <ideia>                  distila e copia XML para clipboard
      c <ideia> -Raw             imprime XML em stdout (implica -NoRefine)
      c <ideia> -Send            envia XML direto para claude -p
      c <ideia> -Model X         usa modelo Ollama compilador diferente (default: prompt-opt)
      c <ideia> -RefinerModel Y  usa modelo Ollama refinador diferente (default: prompt-refiner)
      c <ideia> -NoRefine        pula o estagio refinador, vai direto ao compilador
      c <ideia> -NoCache         ignora cache, forca chamada nova ao Ollama compilador
      c -Last                    imprime ultimo XML do historico
      c -Help                    mostra esta ajuda

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
if (-not (Test-InputAcceptable -Text $userInput -MaxLength $script:MaxInputChars)) {
    if (-not $userInput) {
        Show-Usage
        exit 1
    }
    Write-Host "ERRO: input invalido (vazio ou > $script:MaxInputChars chars)." -ForegroundColor Red
    exit 1
}

if ($Send) {
    try { $null = Resolve-Tool 'claude' } catch {
        Write-Host "ERRO: claude CLI nao encontrado no PATH. Use sem -Send (clipboard)." -ForegroundColor Red
        exit 3
    }
}

$rawInput      = $userInput
$refined       = $false
$metricMode    = 'raw'   # default: refiner not consulted
$refinerMs     = 0
$compilerMs    = 0
$runStart      = [System.Diagnostics.Stopwatch]::StartNew()
$metricsPath   = Join-Path $script:StateRoot 'metrics.jsonl'

# Tri-state cache for ollama PATH lookup: $null = unchecked, $true/$false = result.
$ollamaPresent = $null

# `-Raw` implies `-NoRefine`: scripted use cannot answer prompts interactively.
$skipRefiner = $NoRefine -or $Raw

# Zero-signal pre-gate: inputs with <4 words give the 3B refiner nothing to
# work with, so it hallucinates a topic. Ask ONE deterministic question
# that prompts a richer reformulation, then skip the model refiner entirely.
# Multiple questions hurt the small compiler downstream — keep it to one.
if (-not $skipRefiner -and (Test-InputIsZeroSignal -Text $userInput)) {
    Write-Host '--- input muito vago, reformule ---' -ForegroundColor DarkCyan
    $q = 'reformule em uma frase com area, problema e stack:'
    Write-Host "1) $q" -ForegroundColor Yellow
    $answer = Read-Host '>'
    $pairs = @(@{ Question = $q; Answer = $answer })
    $userInput = Merge-RefinementAnswers -Raw $rawInput -Pairs $pairs
    if ($userInput -ne $rawInput) { $refined = $true }
    $metricMode = 'pregate'
    $skipRefiner = $true
}

if (-not $skipRefiner) {
    try { $null = Resolve-Tool 'ollama'; $ollamaPresent = $true } catch { $ollamaPresent = $false }

    if ($ollamaPresent) {
        Write-Host "--- refinando input ($RefinerModel) ---" -ForegroundColor DarkCyan

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $refinerRaw = ''
        $refinerWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $refinerRaw = ($userInput | & ollama run --nowordwrap $RefinerModel 2>$null | Out-String)
        } catch {
            $refinerRaw = ''
        }
        $refinerWatch.Stop()
        $refinerMs = [int]$refinerWatch.ElapsedMilliseconds
        $ErrorActionPreference = $prevEAP

        $parsed = $null
        if ($refinerRaw -and $LASTEXITCODE -eq 0) {
            $parsed = Get-RefinerOutput $refinerRaw
        }

        if (Test-RefinerOutput $parsed) {
            if ($parsed.Mode -eq 'questions') {
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

$cacheKey = Get-CacheKey -Model $Model -Text $userInput
$xml = $null
$fromCache = $false

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
    try {
        $ollamaOutput = ($userInput | & ollama run --nowordwrap $Model 2>$null | Out-String)
    } catch {
        $compilerWatch.Stop()
        $ErrorActionPreference = $prevEAP
        Write-Host "ERRO: falha ao executar ollama: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }
    $compilerWatch.Stop()
    $compilerMs = [int]$compilerWatch.ElapsedMilliseconds
    $ErrorActionPreference = $prevEAP

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: ollama saiu com codigo $LASTEXITCODE." -ForegroundColor Red
        Write-Host $ollamaOutput -ForegroundColor DarkGray
        exit 5
    }

    $xml = Get-PromptXml $ollamaOutput
    if (-not (Test-PromptXml $xml)) {
        Write-Host "ERRO: saida do otimizador sem XML valido (<task><context><constraints>)." -ForegroundColor Red
        Write-Host "--- saida bruta ---" -ForegroundColor DarkGray
        Write-Host $ollamaOutput -ForegroundColor DarkGray
        exit 6
    }

    if (-not $NoCache) {
        Set-CachedXml -Key $cacheKey -Xml $xml -CacheDir $script:CacheDir
    }
}

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
        totalMs       = [int]$runStart.ElapsedMilliseconds
        cacheHit      = [bool]$fromCache
        flags         = @{
            Raw      = [bool]$Raw
            NoRefine = [bool]$NoRefine
            Send     = [bool]$Send
        }
    }
    Add-MetricEntry -Path $metricsPath -Entry $entry
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
        exit 8
    }
    Write-Host "--- enviando para claude CLI ---" -ForegroundColor Cyan
    # `claude` defaults to interactive. `-p`/`--print` reads stdin and exits.
    $xml | & claude -p
    exit $LASTEXITCODE
} else {
    $xml | Set-Clipboard
    Write-Host "copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude." -ForegroundColor Green
}
