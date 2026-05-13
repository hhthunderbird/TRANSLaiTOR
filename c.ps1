[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Send,
    [switch]$Raw,
    [switch]$Help,
    [string]$Model = 'prompt-opt',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Prompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxInputChars = 4000

function Show-Usage {
    @"
TRANSLaiTOR - local prompt compiler

uso:  c <ideia>            distila e copia XML para clipboard
      c <ideia> -Raw       imprime XML em stdout (scriptavel)
      c <ideia> -Send      envia XML direto para claude -p
      c <ideia> -Model X   usa modelo Ollama diferente (default: prompt-opt)
      c -Help              mostra esta ajuda

limites:
  input maximo: $script:MaxInputChars caracteres
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

$userInput = if ($Prompt) { ($Prompt -join ' ').Trim() } else { '' }
if (-not (Test-InputAcceptable -Text $userInput -MaxLength $script:MaxInputChars)) {
    if (-not $userInput) {
        Show-Usage
        exit 1
    }
    Write-Host "ERRO: input invalido (vazio ou > $script:MaxInputChars chars)." -ForegroundColor Red
    exit 1
}

try { $null = Resolve-Tool 'ollama' } catch {
    Write-Host "ERRO: ollama nao encontrado no PATH." -ForegroundColor Red
    exit 2
}

if ($Send) {
    try { $null = Resolve-Tool 'claude' } catch {
        Write-Host "ERRO: claude CLI nao encontrado no PATH. Use sem -Send (clipboard)." -ForegroundColor Red
        exit 3
    }
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
