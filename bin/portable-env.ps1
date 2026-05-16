param(
  [Parameter(Mandatory=$true)]
  [string]$Root,
  [Parameter(Mandatory=$true)]
  [string]$Platform
)

$PackageDir = Join-Path $Root "packages\$Platform"

$env:HERMES_PORTABLE_ROOT = $Root
$env:HERMES_PORTABLE_PLATFORM = $Platform
$env:HERMES_HOME = Join-Path $Root "data\hermes"
$env:HERMES_PORTABLE_WORKSPACE = Join-Path $Root "data\workspace"
$env:OLLAMA_MODELS = Join-Path $Root "data\ollama-models"
$env:HOME = Join-Path $Root "data\home"
$env:XDG_CONFIG_HOME = Join-Path $Root "data\home\.config"
$env:XDG_CACHE_HOME = Join-Path $Root "data\home\.cache"
$env:XDG_STATE_HOME = Join-Path $Root "data\home\.local\state"
$env:XDG_DATA_HOME = Join-Path $Root "data\home\.local\share"
$env:TMP = Join-Path $Root "data\temp"
$env:TMPDIR = Join-Path $Root "data\temp"
$env:TEMP = Join-Path $Root "data\temp"
$env:UV_CACHE_DIR = Join-Path $PackageDir "uv-cache"
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Root "runtime\$Platform\python"
$env:UV_TOOL_DIR = Join-Path $Root "runtime\$Platform\tools"
$env:PIP_CACHE_DIR = Join-Path $PackageDir "pip-cache"
$env:PYTHONPYCACHEPREFIX = Join-Path $Root "data\temp\pycache"

$env:Path = @(
  (Join-Path $Root "runtime\$Platform\python\Scripts")
  (Join-Path $Root "runtime\$Platform\python")
  (Join-Path $Root "runtime\$Platform")
  $env:Path
) -join ";"

$dirs = @(
  $env:HERMES_HOME
  $env:HERMES_PORTABLE_WORKSPACE
  $env:HOME
  $env:XDG_CONFIG_HOME
  $env:XDG_CACHE_HOME
  $env:XDG_STATE_HOME
  $env:XDG_DATA_HOME
  $env:TMPDIR
  $env:UV_CACHE_DIR
  $env:PIP_CACHE_DIR
  (Join-Path $Root "packages\downloads")
  (Join-Path $Root "logs")
)

foreach ($dir in $dirs) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
