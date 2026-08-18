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

ui_step "Running health checks on all services..."
cd "$PROJECT_ROOT"
uv run python bootstrap.py verify

if [[ $? -eq 0 ]]; then
  ui_success "All services are healthy"
else
  ui_error "Some services failed health checks"
  exit 1
fi