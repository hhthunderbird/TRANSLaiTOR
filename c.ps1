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

$rawInput = $userInput
$refined  = $false

# `-Raw` implies `-NoRefine`: scripted use cannot answer prompts interactively.
$skipRefiner = $NoRefine -or $Raw

if (-not $skipRefiner) {
    $refinerAvailable = $true
    try { $null = Resolve-Tool 'ollama' } catch { $refinerAvailable = $false }

    if ($refinerAvailable) {
        if (-not $Raw) {
            Write-Host "--- refinando input ($RefinerModel) ---" -ForegroundColor DarkCyan
        }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $refinerRaw = ''
        try {
            $refinerRaw = ($userInput | & ollama run $RefinerModel 2>$null | Out-String)
        } catch {
            $refinerRaw = ''
        }
        $ErrorActionPreference = $prevEAP

        $parsed = $null
        if ($refinerRaw -and $LASTEXITCODE -eq 0) {
            $parsed = Get-RefinerOutput $refinerRaw
        }

        if (Test-RefinerOutput $parsed) {
            if ($parsed.Mode -eq 'questions') {
                $pairs = @()
                $i = 1
                foreach ($q in $parsed.Payload) {
                    Write-Host "$i) $q" -ForegroundColor Yellow
                    $answer = Read-Host '>'
                    $pairs += @{ Question = $q; Answer = $answer }
                    $i++
                }
                $userInput = Merge-RefinementAnswers -Raw $rawInput -Pairs $pairs
                if ($userInput -ne $rawInput) { $refined = $true }
            }
            # Mode = 'passthrough' → leave $userInput alone, $refined stays $false.
        } else {
            # Refiner failed or returned garbage. Fall back silently to raw.
            if (-not $Raw) {
                Write-Host "(refiner sem saida util - usando input cru)" -ForegroundColor DarkGray
            }
        }
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
        if (-not $Raw) {
            Write-Host "--- cache hit ($Model) ---" -ForegroundColor DarkGreen
        }
    }
}

if (-not $xml) {
    try { $null = Resolve-Tool 'ollama' } catch {
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
    try {
        $ollamaOutput = ($userInput | & ollama run $Model 2>$null | Out-String)
    } catch {
        $ErrorActionPreference = $prevEAP
        Write-Host "ERRO: falha ao executar ollama: $($_.Exception.Message)" -ForegroundColor Red
        exit 4
    }
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

if ($Raw) {
    Write-Output $xml
    exit 0
}

Write-Host "`n$xml`n" -ForegroundColor Gray

if ($Send) {
    Write-Host "--- enviando para claude CLI ---" -ForegroundColor Cyan
    # `claude` defaults to interactive. `-p`/`--print` reads stdin and exits.
    $xml | & claude -p
    exit $LASTEXITCODE
} else {
    $xml | Set-Clipboard
    Write-Host "copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude." -ForegroundColor Green
}
