#!/usr/bin/env sh
set -eu

ROOT=${PORTABLE_ENV_ROOT:-${ROOT:-}}
PLATFORM=${PORTABLE_ENV_PLATFORM:-${PLATFORM:-}}

if [ -z "$ROOT" ] || [ -z "$PLATFORM" ]; then
  if [ "$#" -ge 2 ]; then
    ROOT=$1
    PLATFORM=$2
  else
    echo "portable-env.sh requires ROOT and PLATFORM."
    return 1 2>/dev/null || exit 1
  fi
fi

RUNTIME_DIR="$ROOT/runtime/$PLATFORM"
PACKAGE_DIR="$ROOT/packages/$PLATFORM"
UV_BIN="$RUNTIME_DIR/uv"

# Find python3 dynamically (uv installs into versioned subdirs)
PYTHON_BIN=$(find "$RUNTIME_DIR/python" -name "python3" -type f -not -path "*/venv/*" -not -path "*/.venv/*" 2>/dev/null | head -1)
if [ -n "$PYTHON_BIN" ]; then
  PYTHON_DIR=$(dirname "$PYTHON_BIN")
else
  PYTHON_DIR="$RUNTIME_DIR/python/bin"
fi

export HERMES_PORTABLE_ROOT="$ROOT"
export HERMES_PORTABLE_PLATFORM="$PLATFORM"
export HERMES_HOME="$ROOT/data/hermes"
export HERMES_PORTABLE_WORKSPACE="$ROOT/data/workspace"
export HOME="$ROOT/data/home"
export XDG_CONFIG_HOME="$ROOT/data/home/.config"
export XDG_CACHE_HOME="$ROOT/data/home/.cache"
export XDG_STATE_HOME="$ROOT/data/home/.local/state"
export XDG_DATA_HOME="$ROOT/data/home/.local/share"
export TMPDIR="$ROOT/data/temp"
export UV_CACHE_DIR="$PACKAGE_DIR/uv-cache"
export PYTHONPYCACHEPREFIX="$ROOT/data/temp/pycache"
export PIP_CACHE_DIR="$PACKAGE_DIR/pip-cache"

# Force uv to use this directory for Python installations
export UV_PYTHON_INSTALL_DIR="$RUNTIME_DIR/python"
export UV_TOOL_DIR="$RUNTIME_DIR/tools"

export PATH="$PYTHON_DIR:$RUNTIME_DIR:$HERMES_HOME/bin:$PATH"

mkdir -p \
  "$HERMES_HOME" \
  "$HERMES_PORTABLE_WORKSPACE" \
  "$ROOT/data/home" \
  "$XDG_CONFIG_HOME" \
  "$XDG_CACHE_HOME" \
  "$XDG_STATE_HOME" \
  "$XDG_DATA_HOME" \
  "$TMPDIR" \
  "$UV_CACHE_DIR" \
  "$PIP_CACHE_DIR" \
  "$ROOT/packages/downloads" \
  "$ROOT/logs"
