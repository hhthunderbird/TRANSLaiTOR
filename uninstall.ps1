<#
.SYNOPSIS
    Removes TRANSLaiTOR's local Ollama models and reverts the user-level
    PATH/PATHEXT changes made by install.ps1. Optional switches purge
    the llama3.2:3b base model, the local state directory, and the
    install directory's runtime files.

.DESCRIPTION
    Default behaviour: remove prompt-opt / prompt-refiner, drop the
    install directory from user PATH, drop .PS1 from user PATHEXT,
    and remove the /c slash command file from the Claude Code
    commands directory.
    -InstallDir   overrides the install directory removed from PATH
                  (default %USERPROFILE%\Scripts, matching install.ps1).
    -CommandsDir  overrides the Claude Code commands directory where
                  c.md was installed (default %USERPROFILE%\.claude\commands).
    -PurgeBase    additionally removes llama3.2:3b.
    -PurgeState   additionally deletes %USERPROFILE%\.cprompt (cache,
                  history, metrics).
    -PurgeInstall additionally deletes the runtime files copied into
                  the install directory by install.ps1.
    -Force        skips the per-step confirmation prompt.
#>
[CmdletBinding()]
param(
    [string]$BaseModel    = 'llama3.2:3b',
    [string]$CompilerName = 'prompt-opt',
    [string]$RefinerName  = 'prompt-refiner',
    [string]$InstallDir   = (Join-Path $env:USERPROFILE 'Scripts'),
    [string]$CommandsDir  = (Join-Path $env:USERPROFILE '.claude\commands'),
    [switch]$PurgeBase,
    [switch]$PurgeState,
    [switch]$PurgeInstall,
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
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & ollama rm $Name 2>$null | Out-Null
    } catch {
        # ollama rm exits nonzero if the model was already absent — swallow it.
    }
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        Write-Host "(modelo $Name ja ausente ou rm falhou - codigo $LASTEXITCODE)" -ForegroundColor DarkGray
    }
}

function Update-UserEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewValue
    )
    [Environment]::SetEnvironmentVariable($Name, $NewValue, 'User')
}

# --- Confirm ---
$cmdFile = Join-Path $CommandsDir 'c.md'
$pathExtStampPreview = Join-Path $env:USERPROFILE '.cprompt\.pathext-stamp'
$pathExtSummary = if (Test-Path -LiteralPath $pathExtStampPreview) {
    'remover .PS1 do PATHEXT (user) - foi adicionado por install.ps1'
} else {
    'PRESERVAR .PS1 em PATHEXT (sem stamp - nao foi adicionado por install.ps1)'
}
$summary = @(
    "remover modelo $CompilerName",
    "remover modelo $RefinerName",
    "remover $InstallDir do PATH (user)",
    $pathExtSummary,
    "remover slash command $cmdFile (se presente)"
)
if ($PurgeBase)    { $summary += "remover base model $BaseModel" }
if ($PurgeState)   { $summary += "apagar $env:USERPROFILE\.cprompt (cache+history+metrics)" }
if ($PurgeInstall) { $summary += "apagar runtime files em $InstallDir" }
Write-Host 'desinstalacao planejada:' -ForegroundColor Cyan
foreach ($line in $summary) { Write-Host "  - $line" }
Confirm-Or-Exit 'prosseguir?'

# --- Local models ---
Remove-OllamaModel -Name $CompilerName
Remove-OllamaModel -Name $RefinerName

# --- PATH ---
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newPath  = Remove-PathEntry -PathString $userPath -Entry $InstallDir
if ($newPath -ne $userPath) {
    Update-UserEnv -Name 'Path' -NewValue $newPath
    Write-Host "PATH (user) limpo: $InstallDir removido." -ForegroundColor DarkGreen
} else {
    Write-Host "PATH (user) nao continha $InstallDir." -ForegroundColor DarkGray
}

# --- Slash command ---
if (Test-Path -LiteralPath $cmdFile) {
    Remove-Item -LiteralPath $cmdFile -Force
    Write-Host "slash command $cmdFile removido." -ForegroundColor DarkGreen
} else {
    Write-Host "slash command $cmdFile nao existia." -ForegroundColor DarkGray
}

# --- PATHEXT ---
$pathExtStampPath = Join-Path $env:USERPROFILE '.cprompt\.pathext-stamp'
$userExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'User')
if (Test-PathExtShouldRemove -PathExtString $userExt -Entry '.PS1' -StampPath $pathExtStampPath) {
    $newExt = Remove-PathEntry -PathString $userExt -Entry '.PS1'
    Update-UserEnv -Name 'PATHEXT' -NewValue $newExt
    Remove-Item -LiteralPath $pathExtStampPath -Force -ErrorAction SilentlyContinue
    Write-Host 'PATHEXT (user) limpo: .PS1 removido (instalado por install.ps1).' -ForegroundColor DarkGreen
} else {
    Write-Host 'PATHEXT (user) preservado: .PS1 nao foi adicionado por install.ps1 (sem stamp).' -ForegroundColor DarkGray
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

# --- Install directory runtime files (opt-in) ---
if ($PurgeInstall) {
    $RuntimeFiles = @(
        'c.ps1','c.cmd','cprompt.psm1','cstats.ps1',
        'cinstall.psm1','Modelfile.compiler','Modelfile.refiner',
        'uninstall.ps1'
    )
    if (Test-Path -LiteralPath $InstallDir) {
        foreach ($file in $RuntimeFiles) {
            $target = Join-Path $InstallDir $file
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force
            }
        }
        Write-Host "runtime files em $InstallDir apagados." -ForegroundColor DarkGreen
        $remaining = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $InstallDir -Force
            Write-Host "$InstallDir (vazio) removido." -ForegroundColor DarkGreen
        } else {
            Write-Host "$InstallDir contem outros arquivos, preservado." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "$InstallDir nao existia." -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'desinstalacao concluida. abra um shell NOVO para PATH/PATHEXT entrarem em efeito.' -ForegroundColor Green
