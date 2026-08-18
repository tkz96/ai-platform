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
while ! command -v uv >/dev/null 2>&1; do
  ui_step "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh || true

  # Add uv to PATH
  if [[ -f "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if command -v uv >/dev/null 2>&1; then
    break
  fi

  ui_recoverable "uv installation failed." "Check your internet connection or install uv manually (curl -LsSf https://astral.sh/uv/install.sh | sh), then press Enter to re-check."
done

uv_version=$(uv --version | awk '{print $2}')
ui_success "uv $uv_version installed"

# Sync project dependencies
ui_section "Project Dependencies"

while true; do
  ui_step "Syncing project dependencies with uv..."
  cd "$PROJECT_ROOT"
  if uv sync; then
    ui_success "Project dependencies synced"
    break
  fi

  ui_recoverable "Failed to sync project dependencies with uv." "Check your network connection or run 'uv sync' in the project directory, then press Enter to retry."
done