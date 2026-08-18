#!/usr/bin/env bash
# Phase 5: Install Podman and initialize machine
# Installs Podman, initializes the Linux VM, and starts it.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/podman.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/.install-state"

ui_section "Podman"

# Ensure Homebrew is in PATH
if [[ "$(uname -m)" == "arm64" ]] && [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install Podman
podman_install

# Get machine configuration from state
machine_name=$(state_get_podman_machine "name" "ai-platform")
machine_cpus=$(state_get_podman_machine "cpus" "4")
machine_memory=$(state_get_podman_machine "memory_mb" "8192")
machine_disk=$(state_get_podman_machine "disk_gb" "60")

# Initialize Podman machine
# If the machine already exists (e.g. from a previous failed run), skip init
# and proceed directly to start — idempotent by design.
if podman_machine_exists "$machine_name"; then
  ui_success "Podman machine '$machine_name' already exists — skipping init"
else
  podman_machine_init "$machine_name" "$machine_cpus" "$machine_memory" "$machine_disk"
fi

# Start Podman machine (start is also idempotent via podman_machine_start)
podman_machine_start "$machine_name"

# Verify Podman is functional
while true; do
  ui_step "Verifying Podman connectivity..."
  if podman info >/dev/null 2>&1; then
    ui_success "Podman is ready"
    break
  fi

  ui_recoverable "Podman is not responding." "Check Podman machine status with 'podman machine list' or restart with 'podman machine start $machine_name'.\n  Press Enter to re-check."
done