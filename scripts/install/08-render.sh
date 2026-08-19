#!/usr/bin/env bash
# Phase 8: Render configuration
# Validates platform config and generates compose.yaml and configs/.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ui_section "Rendering Configuration"

# Ensure uv is in PATH
if [[ -f "$HOME/.local/bin/uv" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

while true; do
  ui_step "Validating platform configuration and rendering templates..."
  cd "$PROJECT_ROOT"
  if uv run python bootstrap.py render; then
    ui_success "Configuration rendered successfully"
    break
  fi

  if ! ui_recoverable "Configuration rendering failed." "Check platform.yaml syntax and template files, then press Enter to retry."; then
    exit 1
  fi
done