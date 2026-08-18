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
tools=("git" "curl" "jq" "yq" "wget" "dnsmasq")

for tool in "${tools[@]}"; do
  while ! command -v "$tool" >/dev/null 2>&1; do
    ui_step "Installing $tool via Homebrew..."
    brew install "$tool" || true
    if command -v "$tool" >/dev/null 2>&1; then
      break
    fi
    ui_recoverable "Failed to install $tool via Homebrew." "Check your internet connection or install $tool manually (brew install $tool), then press Enter to re-check."
  done
  ui_success "$tool installed"
done

ui_success "All system tools installed"