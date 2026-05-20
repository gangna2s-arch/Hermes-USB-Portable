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
  $realPython = Get-ChildItem $PythonDir -Filter "python*.exe" -Recurse |
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
  Write-Host ("-" * 72)
}

function Invoke-Hermes([string[]]$Args) {
  & $PythonExe $HermesBin @Args
}

# ============================================================================
# Main setup
# ============================================================================
Install-UvIfNeeded
Install-PythonIfNeeded
Install-HermesRepo
Install-HermesIfNeeded
New-ConfigIfNeeded

Write-Step "Portable runtime ready"
Write-Host ""
Write-Host "  Hermes USB Portable uses cloud AI providers by default."
Write-Host "  Run 'Setup / Change AI' to configure your provider."
Write-Host "  Supported: OpenRouter, Anthropic, OpenAI, Google, DeepSeek, and more."
Write-Host "  For local LLMs, install Ollama separately and use provider: ollama."
Write-Host ""
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
        Write-Host "3. Status           0. Back"
        Write-Host "4. Gateway Logs"
        Write-Host
        $t = Read-Host "Select"
        switch ($t) {
          "1" { Invoke-Hermes @("setup"); Start-Gateway -Force }
          "2" { Invoke-Hermes @("doctor") }
          "3" { Invoke-Hermes @("status") }
          "4" { if (Test-Path $GatewayLog) { Get-Content $GatewayLog -Tail 80 } }
          "5" { Update-Hermes }
          "6" { Stop-Gateway }
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
