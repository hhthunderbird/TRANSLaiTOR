<#
.SYNOPSIS
    Installs TRANSLaiTOR locally: copies runtime files to an install
    directory (default %USERPROFILE%\Scripts), builds the two Ollama
    models, adds the install directory to the user-level PATH, and
    registers .PS1 in PATHEXT (opt-out via -NoPathExt).

.DESCRIPTION
    Idempotent — re-running re-copies runtime files and skips
    already-completed env changes. The dev/source tree (where this
    script lives) stays separate from the install target so the .git
    repo is not on PATH. Requires Ollama already installed (MSI from
    ollama.com). No admin elevation needed; all changes happen at the
    user scope.
#>
[CmdletBinding()]
param(
    [string]$BaseModel    = 'llama3.2:3b',
    [string]$CompilerName = 'prompt-opt',
    [string]$RefinerName  = 'prompt-refiner',
    [string]$InstallDir   = (Join-Path $env:USERPROFILE 'Scripts'),
    [string]$CommandsDir  = (Join-Path $env:USERPROFILE '.claude\commands'),
    [switch]$NoPathExt,
    [switch]$NoSlashCommand,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'cinstall.psm1') -Force

# Runtime files that must be present in $InstallDir for the CLI to work.
# install.ps1 itself is deliberately NOT copied — it runs from the dev tree.
$RuntimeFiles = @(
    'c.ps1',
    'c.cmd',
    'cprompt.psm1',
    'cstats.ps1',
    'cinstall.psm1',
    'Modelfile.compiler',
    'Modelfile.refiner',
    'uninstall.ps1'
)

function Copy-RuntimeFiles {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string[]]$Files
    )
    if ($Source -eq $Destination) {
        Write-Host "InstallDir == source ($Source), pulando copia." -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Host "criado $Destination" -ForegroundColor DarkGreen
    }
    foreach ($file in $Files) {
        $src = Join-Path $Source $file
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Host "ERRO: arquivo runtime ausente no source: $src" -ForegroundColor Red
            exit 6
        }
        Copy-Item -LiteralPath $src -Destination $Destination -Force
    }
    Write-Host "$($Files.Count) arquivos copiados para $Destination." -ForegroundColor DarkGreen
}

function Resolve-OllamaOrFail {
    $cmd = Get-Command 'ollama' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host 'ERRO: ollama nao encontrado no PATH.' -ForegroundColor Red
        Write-Host 'Instale o Ollama MSI primeiro: https://ollama.com' -ForegroundColor Yellow
        exit 2
    }
    return $cmd.Source
}

function Test-OllamaModelPresent {
    param([Parameter(Mandatory)][string]$Name)
    $list = & ollama list 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { return $false }
    # `ollama list` prints a column-aligned table; match the name at start of line.
    return [bool]([regex]::IsMatch($list, "(?im)^$([regex]::Escape($Name))(\:[^\s]+)?\s"))
}

function Invoke-OllamaCreate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Modelfile
    )
    if (-not (Test-Path -LiteralPath $Modelfile)) {
        Write-Host "ERRO: Modelfile nao encontrado: $Modelfile" -ForegroundColor Red
        exit 3
    }
    Write-Host "--- criando modelo $Name ---" -ForegroundColor Cyan
    & ollama create $Name -f $Modelfile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: ollama create $Name falhou (codigo $LASTEXITCODE)." -ForegroundColor Red
        exit 4
    }
}

function Update-UserEnv {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NewValue
    )
    [Environment]::SetEnvironmentVariable($Name, $NewValue, 'User')
}

# --- Step 0: copy runtime files to install dir ---
Write-Host "--- copiando runtime para $InstallDir ---" -ForegroundColor Cyan
Copy-RuntimeFiles -Source $here -Destination $InstallDir -Files $RuntimeFiles

# --- Step 0b: install /c slash command for Claude Code ---
if (-not $NoSlashCommand) {
    $cmdSrc = Join-Path $here 'commands\c.md'
    if (Test-Path -LiteralPath $cmdSrc) {
        if (-not (Test-Path -LiteralPath $CommandsDir)) {
            New-Item -ItemType Directory -Path $CommandsDir -Force | Out-Null
            Write-Host "criado $CommandsDir" -ForegroundColor DarkGreen
        }
        Copy-Item -LiteralPath $cmdSrc -Destination $CommandsDir -Force
        Write-Host "slash command instalado: $CommandsDir\c.md" -ForegroundColor DarkGreen
    } else {
        Write-Host "AVISO: commands\c.md ausente no source ($cmdSrc), pulando slash command." -ForegroundColor Yellow
    }
} else {
    Write-Host '(pulando slash command /c por -NoSlashCommand)' -ForegroundColor DarkGray
}

# --- Step 1: ollama present? ---
$null = Resolve-OllamaOrFail
Write-Host "ollama OK: $(& ollama --version 2>$null)" -ForegroundColor DarkGreen

# --- Step 2: base model present? ---
if (Test-OllamaModelPresent -Name $BaseModel) {
    Write-Host "base model $BaseModel ja presente, pulando pull." -ForegroundColor DarkGreen
} else {
    Write-Host "--- baixando $BaseModel (pode demorar uns minutos) ---" -ForegroundColor Cyan
    & ollama pull $BaseModel
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: ollama pull $BaseModel falhou (codigo $LASTEXITCODE)." -ForegroundColor Red
        exit 5
    }
}

# --- Step 3: local models ---
if (Test-OllamaModelPresent -Name $CompilerName) {
    Write-Host "modelo $CompilerName ja existe, recriando para refletir Modelfile.compiler." -ForegroundColor DarkGreen
}
Invoke-OllamaCreate -Name $CompilerName -Modelfile (Join-Path $here 'Modelfile.compiler')

if (Test-OllamaModelPresent -Name $RefinerName) {
    Write-Host "modelo $RefinerName ja existe, recriando para refletir Modelfile.refiner." -ForegroundColor DarkGreen
}
Invoke-OllamaCreate -Name $RefinerName -Modelfile (Join-Path $here 'Modelfile.refiner')

# --- Step 4: PATH ---
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newPath  = Add-PathEntry -PathString $userPath -Entry $InstallDir
if ($newPath -ne $userPath) {
    Update-UserEnv -Name 'Path' -NewValue $newPath
    Write-Host "PATH (user) atualizado: $InstallDir adicionado." -ForegroundColor DarkGreen
} else {
    Write-Host "PATH (user) ja contem $InstallDir, nada a fazer." -ForegroundColor DarkGreen
}

# --- Step 5: PATHEXT (opcional) ---
if (-not $NoPathExt) {
    $userExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'User')
    $newExt  = Add-PathEntry -PathString $userExt -Entry '.PS1'
    if ($newExt -ne $userExt) {
        Update-UserEnv -Name 'PATHEXT' -NewValue $newExt
        Write-Host "PATHEXT (user) atualizado: .PS1 adicionado." -ForegroundColor DarkGreen
    } else {
        Write-Host "PATHEXT (user) ja contem .PS1, nada a fazer." -ForegroundColor DarkGreen
    }
} else {
    Write-Host '(pulando PATHEXT por -NoPathExt; use o c.cmd shim para invocar c sem .ps1)' -ForegroundColor DarkGray
}

# --- Step 6: smoke (opcional) ---
if (-not $SkipSmoke) {
    Write-Host "--- smoke test: c -NoRefine -Raw 'sistema de tiro no ecs unity' ---" -ForegroundColor Cyan
    Import-Module (Join-Path $InstallDir 'cprompt.psm1') -Force
    $smokeOut = & (Join-Path $InstallDir 'c.ps1') -NoRefine -Raw 'sistema de tiro no ecs unity' 2>&1 | Out-String
    $smokeExit = $LASTEXITCODE
    $smokeXml = $smokeOut.Trim()
    if ($smokeExit -ne 0) {
        Write-Host "ERRO: smoke retornou codigo $smokeExit." -ForegroundColor Red
        Write-Host "stdout: $smokeXml" -ForegroundColor DarkGray
        exit 9
    }
    if (-not (Test-PromptXml -Xml $smokeXml)) {
        Write-Host "ERRO: smoke saiu zero mas output nao casou <task>/<context>/<constraints>." -ForegroundColor Red
        Write-Host "stdout: $smokeXml" -ForegroundColor DarkGray
        exit 9
    }
    Write-Host 'smoke OK.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'instalacao concluida. abra um shell NOVO para PATH/PATHEXT entrarem em efeito.' -ForegroundColor Green
