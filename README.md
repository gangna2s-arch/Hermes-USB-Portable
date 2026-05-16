# Hermes USB Portable 🐯

Run [Hermes Agent](https://github.com/NousResearch/hermes-agent) from a portable workspace on Windows, Linux, and macOS.

<p>
  <img alt="Windows" src="https://img.shields.io/badge/Windows-run.bat-0078D4?style=flat-square">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-run.sh-FCC624?style=flat-square">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-run.sh-000000?style=flat-square">
  <img alt="Hermes" src="https://img.shields.io/badge/Hermes%20Agent-portable-6366f1?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square">
</p>

Hermes USB Portable is a launcher for people who want the same Hermes Agent workspace available across multiple computers without installing Python, uv, or Hermes globally on each machine.

```text
run.bat   Windows
run.sh    Linux and macOS
```

## What It Does ✨

- Downloads a portable **uv** (Python package manager, ~30 MB single binary) into this project on first run.
- Installs a portable **Python 3.11** via uv.
- Clones hermes-agent and installs it into a project-local venv.
- Keeps Hermes config, sessions, memory, skills, and workspace files under `data/`.
- Uses one shared portable workspace across Windows, Linux, and macOS.

**Based on OpenClaw USB Portable** — adapted for Hermes Agent with `uv` instead of Node.js.

## Quick Start 🚀

### Linux and macOS

```bash
sh run.sh
```

### Windows

Double-click `run.bat` or from PowerShell:

```powershell
.\run.bat
```

**First run on each OS needs internet** to download uv + Python + Hermes (~500 MB). After that, reuse is instant.

## Main Menu

```text
Portable Hermes Agent

1. Setup / Change AI
2. Chat
3. Dashboard
4. Tools
5. Run Hermes Command
0. Exit
```

## Portable Data Model

Shared state lives under `data/`:

```text
data/
  hermes/       Hermes config (config.yaml, .env)
  workspace/    Files the agent works on
  home/         Portable home directory
  temp/         Temporary files
```

Platform-specific files:

```text
runtime/        uv binaries + portable Python (per OS)
packages/       hermes-agent repo + venv (per OS)
logs/           Gateway and install logs
```

## Project Layout

```text
Hermes-USB-Portable/
  run.bat
  run.sh
  README.md
  .gitignore
  .gitattributes

  bin/
    unix.sh              Linux/macOS launcher
    windows.ps1          Windows launcher
    portable-env.sh      Environment variables (Unix)
    portable-env.ps1     Environment variables (Windows)

  templates/
    config.yaml          Default Hermes config

  data/                  (gitignored — your private state)
```

## Notes

- First run per OS requires internet (~500 MB download for Hermes, +100 MB if Ollama is used).
- Uses port 18790 for the Gateway, 11434 for Ollama.
- API keys go in `data/hermes/.env` — never commit this.
- Skills are stored per-OS in the venv, workspace data is shared.

## Credits

Adapted from [OpenClaw USB Portable](https://github.com/nicholasgriffintn?tab=repositories).
Uses [uv](https://github.com/astral-sh/uv) by Astral for portable Python.
