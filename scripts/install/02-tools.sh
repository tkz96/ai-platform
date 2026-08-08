#!/usr/bin/env bash
# Phase 2: Install system tools
# Installs git, curl, jq, and other required utilities.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

ui_section "System Tools"

# Ensure Homebrew is in PATH
if [[ "$(uname -m)" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Check and install each tool
tools=("git" "curl" "jq" "yq" "wget")

for tool in "${tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    ui_success "$tool installed"
  else
    ui_step "Installing $tool..."
    brew install "$tool"
    if command -v "$tool" >/dev/null 2>&1; then
      ui_success "$tool installed"
    else
      ui_error "Failed to install $tool"
      exit 1
    fi
  fi
done

ui_success "All system tools installed"