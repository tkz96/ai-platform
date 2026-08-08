#!/usr/bin/env bash
# Phase 6: Validate ports
# Checks all required ports and resolves conflicts interactively.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ports.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/.install-state"

ui_section "Port Validation"

# Check all required ports
port_check_all