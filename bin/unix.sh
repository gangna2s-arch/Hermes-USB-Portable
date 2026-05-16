#!/usr/bin/env sh
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# ============================================================================
# Platform detection
# ============================================================================
UNAME_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
UV_VERSION="0.8.5"

case "$UNAME_OS:$ARCH" in
  linux:x86_64)
    PLATFORM="linux-x64"
    UV_TARBALL="uv-x86_64-unknown-linux-gnu.tar.gz"
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"
    PYTHON_VERSION="3.11"
    ;;
  linux:aarch64|linux:arm64)
    PLATFORM="linux-arm64"
    UV_TARBALL="uv-aarch64-unknown-linux-gnu.tar.gz"
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"
    PYTHON_VERSION="3.11"
    ;;
  darwin:x86_64)
    PLATFORM="macos-x64"
    UV_TARBALL="uv-x86_64-apple-darwin.tar.gz"
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"
    PYTHON_VERSION="3.11"
    ;;
  darwin:arm64)
    PLATFORM="macos-arm64"
    UV_TARBALL="uv-aarch64-apple-darwin.tar.gz"
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TARBALL}"
    PYTHON_VERSION="3.11"
    ;;
  *)
    echo "Unsupported OS/CPU: $UNAME_OS/$ARCH"
    exit 1
    ;;
esac

# ============================================================================
# Load portable environment
# ============================================================================
PORTABLE_ENV_ROOT=$ROOT PORTABLE_ENV_PLATFORM=$PLATFORM . "$SCRIPT_DIR/portable-env.sh"

RUNTIME_DIR="$ROOT/runtime/$PLATFORM"
UV_BIN="$RUNTIME_DIR/uv"
RAW_PYTHON_DIR="$RUNTIME_DIR/python"
# Python binary resolved dynamically after install (uv puts it in a versioned subfolder)
PYTHON_BIN=""
HERMES_REPO="$ROOT/packages/$PLATFORM/hermes-agent"
HERMES_VENV="$HERMES_REPO/.venv"
HERMES_BIN="$HERMES_VENV/bin/hermes"
DOWNLOAD_PATH="$ROOT/packages/downloads/$UV_TARBALL"

# Ollama
OLLAMA_DIR="$RUNTIME_DIR/ollama"
OLLAMA_BIN="$OLLAMA_DIR/bin/ollama"
OLLAMA_PORT=11434
OLLAMA_LOG="$ROOT/logs/ollama-$PLATFORM.log"

case "$PLATFORM" in
  linux-x64)   OLLAMA_TARBALL="ollama-linux-amd64.tgz" ;;
  linux-arm64)  OLLAMA_TARBALL="ollama-linux-arm64.tgz" ;;
  macos-x64)    OLLAMA_TARBALL="ollama-darwin" ;;
  macos-arm64)  OLLAMA_TARBALL="ollama-darwin" ;;
esac
OLLAMA_URL="https://ollama.com/download/$OLLAMA_TARBALL"
OLLAMA_MODELS_DIR="$ROOT/data/ollama-models"

log() {
  printf '[portable-hermes] %s\n' "$1"
}

# ============================================================================
# Download helpers
# ============================================================================
download_file() {
  url=$1
  out=$2
  tmp="$out.partial"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar "$url" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget "$url" -O "$tmp"
  else
    echo "curl or wget is required to download uv on first run."
    exit 1
  fi
  mv "$tmp" "$out"
}

# ============================================================================
# Install uv (portable Python package manager, ~30 MB single binary)
# ============================================================================
install_uv_if_needed() {
  if [ -x "$UV_BIN" ]; then
    log "Portable uv already exists for $PLATFORM"
    return
  fi

  log "Downloading uv $UV_VERSION for $PLATFORM"
  mkdir -p "$ROOT/packages/downloads" "$RUNTIME_DIR"
  download_file "$UV_URL" "$DOWNLOAD_PATH"

  log "Extracting uv"
  tar -xzf "$DOWNLOAD_PATH" -C "$RUNTIME_DIR" --strip-components=1
  chmod +x "$UV_BIN"
  log "uv installed: $("$UV_BIN" --version)"
}

# ============================================================================
# Resolve the actual python3 binary (uv installs into versioned subdirs)
# ============================================================================
resolve_python() {
  if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
    return 0
  fi
  for dir in "$RAW_PYTHON_DIR"/cpython-*/bin/python3 \
             "$RAW_PYTHON_DIR"/python-*/bin/python3; do
    if [ -x "$dir" ]; then PYTHON_BIN="$dir"; return 0; fi
  done 2>/dev/null || true
  echo "Could not find portable Python. Run 'Setup' first."
  return 1
}

# ============================================================================
# Install portable Python via uv
# ============================================================================
install_python_if_needed() {
  # Check if already installed — look for python3 in versioned subdir
  for dir in "$RAW_PYTHON_DIR"/cpython-*/bin/python3 \
             "$RAW_PYTHON_DIR"/python-*/bin/python3; do
    if [ -x "$dir" ]; then PYTHON_BIN="$dir"; break; fi
  done 2>/dev/null || true

  if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
    log "Portable Python already exists for $PLATFORM"
    return 0
  fi

  log "Installing Python $PYTHON_VERSION via uv (portable)"
  "$UV_BIN" python install "$PYTHON_VERSION" --install-dir "$RAW_PYTHON_DIR"

  # uv installs into e.g. cpython-3.11.13-linux-x86_64-gnu/bin/python3
  for dir in "$RAW_PYTHON_DIR"/cpython-*/bin/python3 \
             "$RAW_PYTHON_DIR"/python-*/bin/python3; do
    if [ -x "$dir" ]; then PYTHON_BIN="$dir"; break; fi
  done 2>/dev/null || true

  if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "ERROR: Could not find python3 in $RAW_PYTHON_DIR"
    exit 1
  fi

  log "Python installed: $("$PYTHON_BIN" --version)"
}

# ============================================================================
# Clone hermes-agent repo
# ============================================================================
clone_hermes_if_needed() {
  if [ -d "$HERMES_REPO/.git" ]; then
    log "Hermes repo already exists"
    return
  fi

  log "Cloning hermes-agent repository"
  rm -rf "$HERMES_REPO"
  mkdir -p "$HERMES_REPO"

  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$HERMES_REPO"
  else
    # Fallback: download tarball
    log "git not found, downloading tarball"
    download_file "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz" \
      "$ROOT/packages/downloads/hermes-agent-main.tar.gz"
    tar -xzf "$ROOT/packages/downloads/hermes-agent-main.tar.gz" -C "$HERMES_REPO" --strip-components=1
  fi
}

# ============================================================================
# Install Hermes via pip into portable venv
# ============================================================================
install_hermes_if_needed() {
  if [ -x "$HERMES_BIN" ]; then
    log "Portable Hermes already exists for $PLATFORM"
    return
  fi

  log "Creating venv and installing Hermes for $PLATFORM"

  # Create venv with uv (no pip by default)
  "$UV_BIN" venv "$HERMES_VENV" --python "$PYTHON_BIN"

  # Install into the venv using uv pip
  "$UV_BIN" pip install -e "$HERMES_REPO" --python "$HERMES_VENV/bin/python3"

  log "Hermes installed: $("$HERMES_BIN" --version 2>&1 || echo 'checking...')"
}

# ============================================================================
# Update Hermes
# ============================================================================
update_hermes() {
  log "Updating Hermes..."
  if [ -d "$HERMES_REPO/.git" ]; then
    (cd "$HERMES_REPO" && git pull origin main)
  else
    rm -rf "$HERMES_REPO"
    clone_hermes_if_needed
  fi
  "$UV_BIN" pip install -e "$HERMES_REPO" --python "$HERMES_VENV/bin/python3"
  log "Hermes updated"
}

# ============================================================================
# Create config from template
# ============================================================================
create_config_if_needed() {
  if [ -f "$HERMES_HOME/config.yaml" ]; then
    return
  fi

  log "Creating default config"
  mkdir -p "$HERMES_HOME"

  if [ -f "$ROOT/templates/config.yaml" ]; then
    sed "s|\${HERMES_PORTABLE_WORKSPACE}|$HERMES_PORTABLE_WORKSPACE|g" \
      "$ROOT/templates/config.yaml" > "$HERMES_HOME/config.yaml"
  else
    # Minimal default config
    cat > "$HERMES_HOME/config.yaml" << 'HERMES_EOF'
# Hermes USB Portable config
# Edit with "Setup / Change AI" or manually
agents:
  defaults:
    workspace: "${HERMES_PORTABLE_WORKSPACE}"
gateway:
  mode: local
  port: 18790
  bind: loopback
HERMES_EOF
  fi
}

# ============================================================================
# Ollama management
# ============================================================================
install_ollama_if_needed() {
  if [ -x "$OLLAMA_BIN" ]; then
    log "Portable Ollama already exists for $PLATFORM"
    return
  fi

  log "Downloading Ollama for $PLATFORM (~100 MB)"
  mkdir -p "$OLLAMA_DIR/bin" "$OLLAMA_MODELS_DIR"
  local ollama_dl="$ROOT/packages/downloads/$OLLAMA_TARBALL"

  download_file "$OLLAMA_URL" "$ollama_dl"

  if echo "$OLLAMA_TARBALL" | grep -q 'tgz$'; then
    # Linux: extract tgz
    tar -xzf "$ollama_dl" -C "$OLLAMA_DIR/bin"
  else
    # macOS: single binary
    cp "$ollama_dl" "$OLLAMA_BIN"
    chmod +x "$OLLAMA_BIN"
    # On macOS the download is the binary itself, not a tarball
    mv "$ollama_dl" "$OLLAMA_BIN"
    chmod +x "$OLLAMA_BIN"
  fi

  chmod +x "$OLLAMA_BIN" 2>/dev/null || true
  log "Ollama installed"
}

ollama_running() {
  if [ -f "$ROOT/logs/ollama-$PLATFORM.pid" ]; then
    pid=$(cat "$ROOT/logs/ollama-$PLATFORM.pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_ollama() {
  if ollama_running; then
    log "Ollama is already running"
    return
  fi

  if [ ! -x "$OLLAMA_BIN" ]; then
    install_ollama_if_needed
  fi

  log "Starting Ollama (port $OLLAMA_PORT, models: $OLLAMA_MODELS_DIR)"
  OLLAMA_HOST="127.0.0.1:$OLLAMA_PORT" \
  OLLAMA_MODELS="$OLLAMA_MODELS_DIR" \
  nohup "$OLLAMA_BIN" serve > "$OLLAMA_LOG" 2>&1 &
  echo "$!" > "$ROOT/logs/ollama-$PLATFORM.pid"

  # Wait for it to be ready
  local elapsed=0
  while [ "$elapsed" -lt 30 ]; do
    if curl -s "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
      log "Ollama ready on port $OLLAMA_PORT"
      return
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  log "Ollama may still be starting. Check logs/ollama-$PLATFORM.log"
}

stop_ollama() {
  if [ -f "$ROOT/logs/ollama-$PLATFORM.pid" ]; then
    pid=$(cat "$ROOT/logs/ollama-$PLATFORM.pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$ROOT/logs/ollama-$PLATFORM.pid"
    log "Ollama stopped"
  else
    log "Ollama is not running"
  fi
}

ollama_pull_model() {
  if ! ollama_running; then
    echo "Ollama is not running. Start it first."
    pause_menu
    return
  fi

  echo
  echo "Available models to pull:"
  echo "  1. llama3.2:3b   (~2.0 GB) — light, fast"
  echo "  2. llama3.2:1b   (~1.3 GB) — tiny"
  echo "  3. gemma2:2b     (~1.6 GB) — Google"
  echo "  4. qwen2.5:3b    (~1.9 GB) — Chinese/English"
  echo "  5. mistral:7b    (~4.1 GB) — bigger"
  echo "  6. Custom (type model name)"
  echo "  0. Back"
  echo
  printf 'Select model to download: '
  read -r model_choice || return

  case "$model_choice" in
    1) model="llama3.2:3b" ;;
    2) model="llama3.2:1b" ;;
    3) model="gemma2:2b" ;;
    4) model="qwen2.5:3b" ;;
    5) model="mistral:7b" ;;
    6) printf 'Model name (e.g. codellama:7b): '; read -r model ;;
    0) return ;;
    *) return ;;
  esac

  [ -n "$model" ] || return

  echo
  log "Pulling $model (models stored in data/ollama-models/)"
  curl -s "http://127.0.0.1:$OLLAMA_PORT/api/pull" -d "{\"name\":\"$model\"}" |
    "$PYTHON_BIN" -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        if 'total' in d and 'completed' in d:
            pct = int(d['completed']/d['total']*100) if d['total'] else 0
            print(f'\\rDownloading... {pct}%', end='', flush=True)
        elif d.get('status') == 'success':
            print()
            print('Done!')
    except: pass
"
  echo
}

ollama_status() {
  if ollama_running; then
    echo "Ollama: RUNNING (port $OLLAMA_PORT)"
    echo "Models directory: $OLLAMA_MODELS_DIR"
    echo
    echo "Installed models:"
    curl -s "http://127.0.0.1:$OLLAMA_PORT/api/tags" |
      "$PYTHON_BIN" -c "import sys,json; models=json.load(sys.stdin).get('models',[]); [print(f'  - {m[\\\"name\\\"]} ({m.get(\\\"size\\\",0)//1024//1024//1024} GB)') for m in models]" 2>/dev/null ||
      echo "  (could not list models)"
  else
    echo "Ollama: STOPPED"
  fi
}

ollama_menu() {
  while :; do
    show_header
    echo "Ollama (Local LLM)"
    echo
    ollama_status
    echo
    echo "1. Start Ollama"
    echo "2. Stop Ollama"
    echo "3. Pull Model"
    echo "4. List Models"
    echo "5. Delete Model"
    echo "0. Back"
    echo
    printf 'Select: '
    read -r choice || exit 0
    case "$choice" in
      1) start_ollama; pause_menu ;;
      2) stop_ollama; pause_menu ;;
      3) ollama_pull_model; pause_menu ;;
      4) curl -s "http://127.0.0.1:$OLLAMA_PORT/api/tags" | "$PYTHON_BIN" -m json.tool 2>/dev/null; pause_menu ;;
      5) printf 'Model to delete: '; read -r m; [ -n "$m" ] && curl -s -X DELETE "http://127.0.0.1:$OLLAMA_PORT/api/delete" -d "{\"name\":\"$m\"}"; pause_menu ;;
      0) return ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

# ============================================================================
# Gateway management
# ============================================================================
gateway_port_running() {
  "$PYTHON_BIN" -c "
import socket
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect(('127.0.0.1', 18790))
    s.close()
    exit(0)
except:
    exit(1)
" >/dev/null 2>&1
}

gateway_healthy() {
  gateway_port_running && "$HERMES_BIN" gateway health >/dev/null 2>&1
}

stop_gateway() {
  if [ -f "$ROOT/logs/gateway-$PLATFORM.pid" ]; then
    pid=$(cat "$ROOT/logs/gateway-$PLATFORM.pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$ROOT/logs/gateway-$PLATFORM.pid"
  fi
}

start_gateway() {
  force=${1:-}
  if [ "$force" = "force" ]; then
    stop_gateway
    sleep 1
  elif gateway_healthy; then
    return
  elif gateway_port_running; then
    log "Gateway is running but not healthy. Restarting."
    stop_gateway
    sleep 1
  fi

  GATEWAY_LOG="$ROOT/logs/gateway-$PLATFORM.log"

  log "Starting Gateway on port 18790"
  nohup "$HERMES_BIN" gateway run --port 18790 --bind loopback --auth none \
    > "$GATEWAY_LOG" 2>&1 &
  echo "$!" > "$ROOT/logs/gateway-$PLATFORM.pid"

  elapsed=0
  while [ "$elapsed" -lt 120 ]; do
    if gateway_healthy; then
      echo
      echo "--- Gateway log tail ---"
      tail -n 20 "$GATEWAY_LOG" 2>/dev/null || true
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $((elapsed % 10)) -eq 0 ]; then
      printf 'Waiting for Gateway... %ss/120s\n' "$elapsed"
    fi
  done

  echo "Gateway did not start within 120s. Check logs/gateway-$PLATFORM.log"
}

# ============================================================================
# UI helpers
# ============================================================================
pause_menu() {
  printf '\nPress Enter to continue'
  read -r _ || true
}

show_header() {
  clear || true
  echo "Portable Hermes Agent"
  echo "------------------------------------------------------------------------"
  echo "Root      $ROOT"
  echo "Platform  $PLATFORM"
  echo "Hermes    $HERMES_HOME"
  echo "Workspace $HERMES_PORTABLE_WORKSPACE"
  if gateway_port_running; then
    echo "Gateway   RUNNING (port 18790)"
  else
    echo "Gateway   STOPPED"
  fi
  if ollama_running; then
    echo "Ollama    RUNNING (port $OLLAMA_PORT)"
  else
    echo "Ollama    STOPPED"
  fi
  echo "------------------------------------------------------------------------"
}

# ============================================================================
# Run Hermes commands
# ============================================================================
hermes_cmd() {
  if [ ! -x "$HERMES_BIN" ]; then
    echo "Hermes is not installed at $HERMES_BIN"
    exit 1
  fi
  "$HERMES_BIN" "$@"
}

run_hermes_command() {
  echo
  echo "Paste Hermes command, for example:"
  echo "hermes pairing approve telegram R2F8ZL5S"
  printf 'Command: '
  read -r command_text || return
  [ -n "$command_text" ] || return

  case "$command_text" in
    hermes\ *) command_text=${command_text#hermes } ;;
    hermes) return ;;
  esac

  echo
  log "Running Hermes command. Timeout: 90s"
  # shellcheck disable=SC2086
  hermes_cmd $command_text
  pause_menu
}

# ============================================================================
# Tools menu
# ============================================================================
tools_menu() {
  while :; do
    show_header
    echo "Tools"
    echo
    echo "1. Full Setup"
    echo "2. Health Check / Repair"
    echo "3. Status"
    echo "4. Sessions"
    echo "5. Channels"
    echo "6. Gateway Logs"
    echo "7. Update Hermes"
    echo "8. Portable Shell"
    echo "9. Stop Gateway"
    echo "10. Ollama (Local LLM)"
    echo "11. Run Hermes Command"
    echo "0. Back"
    echo
    printf 'Select: '
    read -r choice || exit 0
    case "$choice" in
      1) hermes_cmd setup; start_gateway force; pause_menu ;;
      2) hermes_cmd doctor; pause_menu ;;
      3) hermes_cmd status; pause_menu ;;
      4) hermes_cmd sessions list; pause_menu ;;
      5) hermes_cmd gateway status; pause_menu ;;
      6) if [ -f "$ROOT/logs/gateway-$PLATFORM.log" ]; then
           tail -n 80 "$ROOT/logs/gateway-$PLATFORM.log"
         else
           echo "No Gateway log yet."
         fi
         pause_menu ;;
      7) update_hermes; pause_menu ;;
      8) echo "Portable Hermes shell. Type exit to return."
         "${SHELL:-/bin/sh}" ;;
      9) stop_gateway; pause_menu ;;
      10) ollama_menu ;;
      11) run_hermes_command; pause_menu ;;
      0) return ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

# ============================================================================
# Main setup
# ============================================================================
install_uv_if_needed
. "$SCRIPT_DIR/portable-env.sh"
install_python_if_needed
resolve_python
clone_hermes_if_needed
install_hermes_if_needed
create_config_if_needed

log "Portable runtime ready"
"$PYTHON_BIN" --version
"$UV_BIN" --version
"$HERMES_BIN" --version 2>&1 || true
sleep 1

# ============================================================================
# Main menu loop
# ============================================================================
while :; do
  show_header
  echo "1. Setup / Change AI"
  echo "2. Chat"
  echo "3. Dashboard"
  echo "4. Tools"
  echo "5. Run Hermes Command"
  echo "0. Exit"
  echo
  printf 'Select: '
  read -r choice || exit 0
  case "$choice" in
    1) hermes_cmd setup --section model; start_gateway force; pause_menu ;;
    2) start_gateway; hermes_cmd tui 2>/dev/null || hermes_cmd chat; pause_menu ;;
    3) start_gateway; hermes_cmd dashboard; pause_menu ;;
    4) tools_menu ;;
    5) run_hermes_command; pause_menu ;;
    0) exit 0 ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
done
