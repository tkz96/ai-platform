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

# Check if Python 3.12+ is already available
if command -v python3 >/dev/null 2>&1; then
  py_version=$(python3 --version 2>&1 | awk '{print $2}')
  if python3 -c "import sys; exit(0 if sys.version_info >= (3,12) else 1)" 2>/dev/null; then
    ui_success "Python $py_version (>= 3.12)"
    exit 0
  else
    ui_warning "Python $py_version is too old. Installing Python 3.12+..."
  fi
fi

# Install Python via Homebrew
ui_step "Installing Python 3.12 via Homebrew..."
brew install python@3.12

# Ensure the new Python is in PATH
if [[ -f /opt/homebrew/bin/python3 ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

# Verify
if command -v python3 >/dev/null 2>&1; then
  py_version=$(python3 --version 2>&1 | awk '{print $2}')
  if python3 -c "import sys; exit(0 if sys.version_info >= (3,12) else 1)" 2>/dev/null; then
    ui_success "Python $py_version installed"
  else
    ui_error "Python $py_version does not meet the 3.12+ requirement"
    exit 1
  fi
else
  ui_error "Python installation failed"
  exit 1
fi