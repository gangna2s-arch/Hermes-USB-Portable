$ErrorActionPreference = "Stop"

$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Platform = "windows-x64"
. (Join-Path $PSScriptRoot "portable-env.ps1") -Root $Root -Platform $Platform

$UvVersion = "0.8.5"
$UvZip = "uv-x86_64-pc-windows-msvc.zip"
$UvUrl = "https://github.com/astral-sh/uv/releases/download/$UvVersion/$UvZip"
$DownloadPath = Join-Path $Root "packages\downloads\$UvZip"
$RuntimeDir = Join-Path $Root "runtime\$Platform"
$UvExe = Join-Path $RuntimeDir "uv.exe"
$PythonDir = Join-Path $RuntimeDir "python"
$PythonExe = Join-Path $PythonDir "python.exe"
$HermesRepo = Join-Path $Root "packages\$Platform\hermes-agent"
$HermesVenv = Join-Path $HermesRepo ".venv"
$HermesBin = Join-Path $HermesVenv "Scripts\hermes.exe"
$GatewayLog = Join-Path $Root "logs\gateway-windows.log"
$GatewayPid = Join-Path $Root "logs\gateway-windows.pid"
$OllamaDir = Join-Path $RuntimeDir "ollama"
$OllamaExe = Join-Path $OllamaDir "ollama.exe"
$OllamaModels = Join-Path $Root "data\ollama-models"
$OllamaLog = Join-Path $Root "logs\ollama-windows.log"
$OllamaPid = Join-Path $Root "logs\ollama-windows.pid"

function Write-Step([string]$Text) {
  Write-Host "[portable-hermes] $Text" -ForegroundColor Cyan
}

# ============================================================================
# Install uv
# ============================================================================
function Install-UvIfNeeded {
  if (Test-Path -LiteralPath $UvExe) {
    Write-Step "Portable uv already exists for $Platform"
    return
  }

  Write-Step "Downloading uv $UvVersion for Windows"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DownloadPath), $RuntimeDir | Out-Null
  Invoke-WebRequest -Uri $UvUrl -OutFile $DownloadPath

  Write-Step "Extracting uv"
  Expand-Archive -LiteralPath $DownloadPath -DestinationPath $RuntimeDir -Force
}

# ============================================================================
# Install portable Python via uv
# ============================================================================
function Install-PythonIfNeeded {
  if (Test-Path -LiteralPath $PythonExe) {
    Write-Step "Portable Python already exists for $Platform"
    return
  }

  Write-Step "Installing Python 3.11 via uv (portable)"
  & $UvExe python install 3.11 --install-dir $PythonDir

  # uv names the binary python3.11.exe — copy/rename to python.exe
  $realPython = Get-ChildItem $PythonDir -Filter "python*.exe" |
    Where-Object { $_.Name -match "^python\d" } |
    Select-Object -First 1
  if ($realPython -and $realPython.Name -ne "python.exe") {
    Copy-Item $realPython.FullName (Join-Path $PythonDir "python.exe")
    Write-Step "Copied $($realPython.Name) -> python.exe"
  }
}

# ============================================================================
# Clone hermes-agent repo
# ============================================================================
function Install-HermesRepo {
  if (Test-Path (Join-Path $HermesRepo ".git")) {
    Write-Step "Hermes repo already exists"
    return
  }

  Write-Step "Downloading hermes-agent repository"
  Remove-Item -LiteralPath $HermesRepo -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $HermesRepo | Out-Null

  if (Get-Command git -ErrorAction SilentlyContinue) {
    git clone --depth 1 https://github.com/NousResearch/hermes-agent.git $HermesRepo
  } else {
    $tarball = Join-Path $Root "packages\downloads\hermes-agent-main.zip"
    Invoke-WebRequest -Uri "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.zip" -OutFile $tarball
    Expand-Archive -LiteralPath $tarball -DestinationPath (Join-Path $HermesRepo "..") -Force
    $extracted = Get-ChildItem (Join-Path $HermesRepo "..") | Where-Object { $_.Name -like "hermes-agent-*" }
    if ($extracted) {
      Get-ChildItem $extracted.FullName | Move-Item -Destination $HermesRepo -Force
      Remove-Item $extracted.FullName -Recurse -Force
    }
  }
}

# ============================================================================
# Install Hermes
# ============================================================================
function Install-HermesIfNeeded {
  if (Test-Path -LiteralPath $HermesBin) {
    Write-Step "Portable Hermes already exists for $Platform"
    return
  }

  Write-Step "Creating venv and installing Hermes for $Platform"
  & $UvExe venv $HermesVenv --python $PythonExe
  & $UvExe pip install --python $PythonExe -e $HermesRepo --no-cache
}

# ============================================================================
# Update
# ============================================================================
function Update-Hermes {
  Write-Step "Updating Hermes..."
  if (Test-Path (Join-Path $HermesRepo ".git")) {
    Push-Location $HermesRepo
    git pull origin main
    Pop-Location
  } else {
    Install-HermesRepo
  }
  & $UvExe pip install --python $PythonExe -e $HermesRepo --no-cache
  Write-Step "Hermes updated"
}

# ============================================================================
# Create config
# ============================================================================
function New-ConfigIfNeeded {
  $configPath = Join-Path $env:HERMES_HOME "config.yaml"
  if (Test-Path -LiteralPath $configPath) { return }

  Write-Step "Creating default config"
  New-Item -ItemType Directory -Force -Path $env:HERMES_HOME | Out-Null

  $templatePath = Join-Path $Root "templates\config.yaml"
  if (Test-Path -LiteralPath $templatePath) {
    $content = Get-Content $templatePath -Raw
    $content = $content -replace '\$\{HERMES_PORTABLE_WORKSPACE\}', $env:HERMES_PORTABLE_WORKSPACE
    Set-Content -Path $configPath -Value $content
  } else {
    @"
agents:
  defaults:
    workspace: "$env:HERMES_PORTABLE_WORKSPACE"
gateway:
  mode: local
  port: 18790
  bind: loopback
"@ | Set-Content -Path $configPath
  }
}

# ============================================================================
# Gateway
# ============================================================================
function Test-GatewayPort {
  try {
    $client = New-Object Net.Sockets.TcpClient
    $iar = $client.BeginConnect("127.0.0.1", 18790, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
    if ($ok) { $client.EndConnect($iar) }
    $client.Close()
    return $ok
  } catch {
    return $false
  }
}

function Test-GatewayHealthy {
  if (-not (Test-GatewayPort)) { return $false }
  try {
    & $HermesBin gateway health *> $null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Stop-Gateway {
  if (Test-Path -LiteralPath $GatewayPid) {
    $pid = Get-Content $GatewayPid -Raw
    if ($pid) { Stop-Process -Id ([int]$pid) -Force -ErrorAction SilentlyContinue }
    Remove-Item $GatewayPid -Force -ErrorAction SilentlyContinue
  }
}

function Start-Gateway([switch]$Force) {
  if ($Force) { Stop-Gateway; Start-Sleep 1 }
  elseif (Test-GatewayHealthy) { return }
  elseif (Test-GatewayPort) {
    Write-Host "Gateway is running but not healthy. Restarting." -ForegroundColor Yellow
    Stop-Gateway; Start-Sleep 1
  }

  Write-Step "Starting Gateway on port 18790"
  $proc = Start-Process -FilePath $PythonExe `
    -ArgumentList @($HermesBin, "gateway", "run", "--port", "18790", "--bind", "loopback", "--auth", "none") `
    -WorkingDirectory $Root `
    -RedirectStandardOutput $GatewayLog `
    -RedirectStandardError $GatewayLog `
    -WindowStyle Hidden `
    -PassThru

  $proc.Id | Set-Content $GatewayPid
  Start-Sleep 3
  Write-Host "Gateway started." -ForegroundColor Green
}

# ============================================================================
# Ollama
# ============================================================================
function Test-OllamaRunning {
  if (Test-Path -LiteralPath $OllamaPid) {
    $pid = Get-Content $OllamaPid -Raw
    if ($pid) {
      try {
        $proc = Get-Process -Id ([int]$pid) -ErrorAction SilentlyContinue
        return ($null -ne $proc)
      } catch { return $false }
    }
  }
  return $false
}

function Install-OllamaIfNeeded {
  if (Test-Path -LiteralPath $OllamaExe) {
    Write-Step "Portable Ollama already exists for $Platform"
    return
  }

  Write-Step "Downloading Ollama for Windows (~100 MB)"
  New-Item -ItemType Directory -Force -Path $OllamaDir, $OllamaModels | Out-Null
  $ollamaDl = Join-Path $Root "packages\downloads\ollama-windows.exe"
  Invoke-WebRequest -Uri "https://ollama.com/download/ollama-windows-amd64.exe" -OutFile $ollamaDl
  Move-Item $ollamaDl $OllamaExe -Force
  Write-Step "Ollama installed"
}

function Start-Ollama {
  if (Test-OllamaRunning) {
    Write-Step "Ollama is already running"
    return
  }

  if (-not (Test-Path -LiteralPath $OllamaExe)) {
    Install-OllamaIfNeeded
  }

  Write-Step "Starting Ollama (port 11434, models: $OllamaModels)"
  $env:OLLAMA_HOST = "127.0.0.1:11434"
  $env:OLLAMA_MODELS = $OllamaModels

  $proc = Start-Process -FilePath $OllamaExe `
    -ArgumentList "serve" `
    -RedirectStandardOutput $OllamaLog `
    -RedirectStandardError $OllamaLog `
    -WindowStyle Hidden `
    -PassThru
  $proc.Id | Set-Content $OllamaPid

  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 -ErrorAction SilentlyContinue
      if ($r.StatusCode -eq 200) { Write-Step "Ollama ready on port 11434"; return }
    } catch {}
    Start-Sleep 1
  }
  Write-Step "Ollama may still be starting. Check logs."
}

function Stop-Ollama {
  if (Test-Path -LiteralPath $OllamaPid) {
    $pid = Get-Content $OllamaPid -Raw
    if ($pid) { Stop-Process -Id ([int]$pid) -Force -ErrorAction SilentlyContinue }
    Remove-Item $OllamaPid -Force -ErrorAction SilentlyContinue
    Write-Step "Ollama stopped"
  } else {
    Write-Step "Ollama is not running"
  }
}

function Write-OllamaStatus {
  if (Test-OllamaRunning) {
    Write-Host "Ollama: RUNNING (port 11434)" -ForegroundColor Green
    Write-Host "Models directory: $OllamaModels"
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5
      $models = ($r.Content | ConvertFrom-Json).models
      if ($models) {
        Write-Host "`nInstalled models:"
        foreach ($m in $models) {
          $sizeGB = [math]::Round($m.size / 1GB, 1)
          Write-Host "  - $($m.name) ($sizeGB GB)"
        }
      }
    } catch { Write-Host "  (could not list models)" }
  } else {
    Write-Host "Ollama: STOPPED"
  }
}

function Ollama-PullModel {
  if (-not (Test-OllamaRunning)) {
    Write-Host "Ollama is not running. Start it first." -ForegroundColor Yellow
    Read-Host "Press Enter"
    return
  }

  Write-Host
  Write-Host "Available models to pull:"
  Write-Host "  1. llama3.2:3b   (~2.0 GB) — light, fast"
  Write-Host "  2. llama3.2:1b   (~1.3 GB) — tiny"
  Write-Host "  3. gemma2:2b     (~1.6 GB) — Google"
  Write-Host "  4. qwen2.5:3b    (~1.9 GB) — Chinese/English"
  Write-Host "  5. mistral:7b    (~4.1 GB) — bigger"
  Write-Host "  6. Custom"
  Write-Host "  0. Back"
  Write-Host
  $mc = Read-Host "Select model"

  $model = switch ($mc) {
    "1" { "llama3.2:3b" }
    "2" { "llama3.2:1b" }
    "3" { "gemma2:2b" }
    "4" { "qwen2.5:3b" }
    "5" { "mistral:7b" }
    "6" { Read-Host "Model name" }
    default { $null }
  }
  if (-not $model) { return }

  Write-Host
  Write-Step "Pulling $model (models stored in data/ollama-models/)"
  $body = @{name=$model} | ConvertTo-Json
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/pull" -Method Post -Body $body -ContentType "application/json"
  Write-Host "Done!"
}

function Ollama-Menu {
  do {
    Clear-Host
    Write-Host "Ollama (Local LLM)" -ForegroundColor Magenta
    Write-Host ("-" * 60)
    Write-OllamaStatus
    Write-Host
    Write-Host "1. Start Ollama"
    Write-Host "2. Stop Ollama"
    Write-Host "3. Pull Model"
    Write-Host "0. Back"
    Write-Host
    $t = Read-Host "Select"
    switch ($t) {
      "1" { Start-Ollama }
      "2" { Stop-Ollama }
      "3" { Ollama-PullModel }
      "0" { break }
    }
    if ($t -ne "0") { Read-Host "Press Enter to continue" }
  } while ($t -ne "0")
}

# ============================================================================
# UI
# ============================================================================
function Write-Header {
  Clear-Host
  Write-Host "Portable Hermes Agent" -ForegroundColor Magenta
  Write-Host ("-" * 72)
  Write-Host ("Root      $Root")
  Write-Host ("Platform  $Platform")
  Write-Host ("Hermes    $env:HERMES_HOME")
  Write-Host ("Workspace $env:HERMES_PORTABLE_WORKSPACE")
  if (Test-GatewayPort) { Write-Host "Gateway   RUNNING (port 18790)" -ForegroundColor Green }
  else { Write-Host "Gateway   STOPPED" }
  if (Test-OllamaRunning) { Write-Host "Ollama    RUNNING (port 11434)" -ForegroundColor Green }
  else { Write-Host "Ollama    STOPPED" }
  Write-Host ("-" * 72)
}

function Invoke-Hermes([string[]]$Args) {
  & $PythonExe $HermesBin @Args
}

# ============================================================================
# Main setup
# ============================================================================
Install-UvIfNeeded
. (Join-Path $PSScriptRoot "portable-env.ps1") -Root $Root -Platform $Platform
Install-PythonIfNeeded
Install-HermesRepo
Install-HermesIfNeeded
New-ConfigIfNeeded

Write-Step "Portable runtime ready"
& $PythonExe --version
& $HermesBin --version 2>$null
Start-Sleep 1

# ============================================================================
# Main menu
# ============================================================================
while ($true) {
  Write-Header
  Write-Host "1. Setup / Change AI"
  Write-Host "2. Chat"
  Write-Host "3. Dashboard"
  Write-Host "4. Tools"
  Write-Host "0. Exit"
  Write-Host
  $choice = Read-Host "Select"

  switch ($choice) {
    "1" {
      Invoke-Hermes @("setup", "--section", "model")
      Start-Gateway -Force
      Read-Host "Press Enter to continue"
    }
    "2" {
      Start-Gateway
      Invoke-Hermes @("chat")
    }
    "3" {
      Start-Gateway
      Invoke-Hermes @("dashboard")
      Read-Host "Press Enter to continue"
    }
    "4" {
      do {
        Write-Header
        Write-Host "Tools"
        Write-Host
        Write-Host "1. Full Setup       5. Update Hermes"
        Write-Host "2. Health Check     6. Stop Gateway"
        Write-Host "3. Status           7. Ollama (Local LLM)"
        Write-Host "4. Gateway Logs     0. Back"
        Write-Host
        $t = Read-Host "Select"
        switch ($t) {
          "1" { Invoke-Hermes @("setup"); Start-Gateway -Force }
          "2" { Invoke-Hermes @("doctor") }
          "3" { Invoke-Hermes @("status") }
          "4" { if (Test-Path $GatewayLog) { Get-Content $GatewayLog -Tail 80 } }
          "5" { Update-Hermes }
          "6" { Stop-Gateway }
          "7" { Ollama-Menu }
          "0" { break }
        }
        if ($t -ne "0") { Read-Host "Press Enter to continue" }
      } while ($t -ne "0")
    }
    "0" {
      exit 0
    }
    default {
      Write-Host "Invalid option"
      Start-Sleep 1
    }
  }
}
