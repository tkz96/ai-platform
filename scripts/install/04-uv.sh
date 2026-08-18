#!/usr/bin/env bash
# Phase 4: Install uv and project dependencies
# Installs uv package manager and syncs project dependencies.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ui_section "uv Package Manager"

# Ensure Homebrew is in PATH
if [[ "$(uname -m)" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install uv
if command -v uv >/dev/null 2>&1; then
  uv_version=$(uv --version | awk '{print $2}')
  ui_success "uv $uv_version already installed"
else
  ui_step "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh

  # Add uv to PATH
  if [[ -f "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if command -v uv >/dev/null 2>&1; then
    uv_version=$(uv --version | awk '{print $2}')
    ui_success "uv $uv_version installed"
  else
    ui_error "uv installation failed"
    exit 1
  fi
fi

# Sync project dependencies
ui_section "Project Dependencies"

ui_step "Syncing project dependencies with uv..."
cd "$PROJECT_ROOT"
uv sync

if [[ $? -eq 0 ]]; then
  ui_success "Project dependencies synced"
else
  ui_error "Failed to sync project dependencies"
  exit 1
fi