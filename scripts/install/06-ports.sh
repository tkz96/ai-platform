#!/usr/bin/env bash
# Phase 6: Validate ports
# Checks all required ports and resolves conflicts interactively.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ports.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/.install-state"

# Ensure Homebrew & local binaries are in PATH
if [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Check all required ports (port_check_all renders its own section header)
port_check_all