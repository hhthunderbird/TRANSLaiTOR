<#
.SYNOPSIS
    Installs TRANSLaiTOR locally: builds the two Ollama models, adds the
    script directory to the user-level PATH, and registers .PS1 in
    PATHEXT (opt-out via -NoPathExt).

.DESCRIPTION
    Idempotent — re-running skips already-completed steps. Requires
    Ollama already installed (MSI from ollama.com). No admin elevation
    needed; all changes happen at the user scope.
#>
[CmdletBinding()]
param(
    [string]$BaseModel    = 'llama3.2:3b',
    [string]$CompilerName = 'prompt-opt',
    [string]$RefinerName  = 'prompt-refiner',
    [switch]$NoPathExt,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'cinstall.psm1') -Force

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
$newPath  = Add-PathEntry -PathString $userPath -Entry $here
if ($newPath -ne $userPath) {
    Update-UserEnv -Name 'Path' -NewValue $newPath
    Write-Host "PATH (user) atualizado: $here adicionado." -ForegroundColor DarkGreen
} else {
    Write-Host "PATH (user) ja contem $here, nada a fazer." -ForegroundColor DarkGreen
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
    Write-Host "--- smoke test: c -NoRefine -Raw 'test input' ---" -ForegroundColor Cyan
    & (Join-Path $here 'c.ps1') -NoRefine -Raw 'test input' | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'smoke OK.' -ForegroundColor Green
    } else {
        Write-Host "smoke retornou codigo $LASTEXITCODE (modelo pode estar lento na 1a inferencia; revise manualmente)." -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'instalacao concluida. abra um shell NOVO para PATH/PATHEXT entrarem em efeito.' -ForegroundColor Green
