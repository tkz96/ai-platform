#!/usr/bin/env bash
# Phase 1: Install Homebrew
# Installs Homebrew if not already present.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

ui_section "Homebrew"

if command -v brew >/dev/null 2>&1; then
  brew_version=$(brew --version | head -1 | awk '{print $2}')
  ui_success "Homebrew $brew_version already installed"
  exit 0
fi

while ! command -v brew >/dev/null 2>&1; do
  ui_step "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true

  # Add Homebrew to PATH for Apple Silicon
  if [[ "$(uname -m)" == "arm64" ]]; then
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi

  if command -v brew >/dev/null 2>&1; then
    break
  fi

  ui_recoverable "Homebrew installation failed or was cancelled." "Check your network connection or install Homebrew manually, then press Enter to re-check."
done

brew_version=$(brew --version | head -1 | awk '{print $2}')
ui_success "Homebrew $brew_version installed"