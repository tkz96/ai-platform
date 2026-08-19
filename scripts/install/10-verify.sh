#!/usr/bin/env bash
# Phase 10: Verify services
# Runs health checks on all deployed services.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ui_section "Verifying Services"

# Ensure uv is in PATH
if [[ -f "$HOME/.local/bin/uv" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

while true; do
  ui_step "Running health checks on all services..."
  cd "$PROJECT_ROOT"
  if uv run python bootstrap.py verify; then
    ui_success "All services are healthy"
    break
  fi

  if ! ui_recoverable "Some services failed health checks." "Check logs with: ./bootstrap.sh logs\n  Press Enter to retry health checks."; then
    exit 1
  fi
done