[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Send,
    [switch]$Raw,
    [string]$Model = 'prompt-opt',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Prompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force UTF-8 no-BOM end-to-end (fixes Ollama encoding conflict on Windows)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8NoBom
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

Import-Module (Join-Path $PSScriptRoot 'cprompt.psm1') -Force

$userInput = if ($Prompt) { ($Prompt -join ' ').Trim() } else { '' }
if (-not $userInput) {
    Write-Host "uso: c <ideia>  [-Send] [-Raw] [-Model nome]" -ForegroundColor Yellow
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
