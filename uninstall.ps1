<#
.SYNOPSIS
    Removes TRANSLaiTOR's local Ollama models and reverts the user-level
    PATH/PATHEXT changes made by install.ps1. Optional switches purge
    the llama3.2:3b base model and the local state directory.

.DESCRIPTION
    Default behaviour: remove prompt-opt / prompt-refiner, drop the
    scripts directory from user PATH, drop .PS1 from user PATHEXT.
    -PurgeBase    additionally removes llama3.2:3b.
    -PurgeState   additionally deletes %USERPROFILE%\.cprompt (cache,
                  history, metrics).
    -Force        skips the per-step confirmation prompt.
#>
[CmdletBinding()]
param(
    [string]$BaseModel    = 'llama3.2:3b',
    [string]$CompilerName = 'prompt-opt',
    [string]$RefinerName  = 'prompt-refiner',
    [switch]$PurgeBase,
    [switch]$PurgeState,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'cinstall.psm1') -Force

function Confirm-Or-Exit {
    param([Parameter(Mandatory)][string]$Message)
    if ($Force) { return }
    $reply = Read-Host "$Message [y/N]"
    if ($reply -notmatch '^[yY]') {
        Write-Host 'abortado.' -ForegroundColor Yellow
        exit 0
    }
}

function Remove-OllamaModel {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command 'ollama' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "ollama nao encontrado, pulando rm $Name." -ForegroundColor DarkGray
        return
    }
    Write-Host "--- removendo modelo $Name ---" -ForegroundColor Cyan
    & ollama rm $Name 2>$null
    # `ollama rm` returns nonzero if the model was already absent — silent in that case.
}

function Update-UserEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewValue
    )
    [Environment]::SetEnvironmentVariable($Name, $NewValue, 'User')
}

# --- Confirm ---
$summary = @(
    "remover modelo $CompilerName",
    "remover modelo $RefinerName",
    "remover $here do PATH (user)",
    'remover .PS1 do PATHEXT (user)'
)
if ($PurgeBase)  { $summary += "remover base model $BaseModel" }
if ($PurgeState) { $summary += "apagar $env:USERPROFILE\.cprompt (cache+history+metrics)" }
Write-Host 'desinstalacao planejada:' -ForegroundColor Cyan
foreach ($line in $summary) { Write-Host "  - $line" }
Confirm-Or-Exit 'prosseguir?'

# --- Local models ---
Remove-OllamaModel -Name $CompilerName
Remove-OllamaModel -Name $RefinerName

# --- PATH ---
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newPath  = Remove-PathEntry -PathString $userPath -Entry $here
if ($newPath -ne $userPath) {
    Update-UserEnv -Name 'Path' -NewValue $newPath
    Write-Host "PATH (user) limpo: $here removido." -ForegroundColor DarkGreen
} else {
    Write-Host "PATH (user) nao continha $here." -ForegroundColor DarkGray
}

# --- PATHEXT ---
$userExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'User')
$newExt  = Remove-PathEntry -PathString $userExt -Entry '.PS1'
if ($newExt -ne $userExt) {
    Update-UserEnv -Name 'PATHEXT' -NewValue $newExt
    Write-Host 'PATHEXT (user) limpo: .PS1 removido.' -ForegroundColor DarkGreen
} else {
    Write-Host 'PATHEXT (user) nao continha .PS1.' -ForegroundColor DarkGray
}

# --- Base model (opt-in) ---
if ($PurgeBase) {
    Remove-OllamaModel -Name $BaseModel
}

# --- State directory (opt-in) ---
if ($PurgeState) {
    $stateDir = Join-Path $env:USERPROFILE '.cprompt'
    if (Test-Path -LiteralPath $stateDir) {
        Remove-Item -LiteralPath $stateDir -Recurse -Force
        Write-Host "$stateDir apagado." -ForegroundColor DarkGreen
    } else {
        Write-Host "$stateDir nao existia." -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'desinstalacao concluida. abra um shell NOVO para PATH/PATHEXT entrarem em efeito.' -ForegroundColor Green
