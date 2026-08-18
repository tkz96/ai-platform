#!/usr/bin/env bash
# Phase 3: Install Python
# Installs Python 3.12+ via Homebrew if not already present.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

ui_section "Python"

# Ensure Homebrew is in PATH
if [[ "$(uname -m)" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

while true; do
  if command -v python3 >/dev/null 2>&1; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    if python3 -c "import sys; exit(0 if sys.version_info >= (3,12) else 1)" 2>/dev/null; then
      ui_success "Python $py_version (>= 3.12)"
      break
    else
      ui_warning "Python $py_version is too old. Installing Python 3.12+..."
    fi
  fi

  # Install Python via Homebrew
  ui_step "Installing Python 3.12 via Homebrew..."
  brew install python@3.12 || true

  # Ensure the new Python is in PATH
  if [[ -f /opt/homebrew/bin/python3 ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
  fi

  if command -v python3 >/dev/null 2>&1 && python3 -c "import sys; exit(0 if sys.version_info >= (3,12) else 1)" 2>/dev/null; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    ui_success "Python $py_version installed"
    break
  fi

  ui_recoverable "Python 3.12+ installation failed." "Install Python 3.12+ manually (brew install python@3.12), then press Enter to re-check."
done