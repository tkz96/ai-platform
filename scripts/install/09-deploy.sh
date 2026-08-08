#!/usr/bin/env bash
# Phase 9: Deploy services
# Pulls pinned images and starts services in dependency order.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/podman.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ui_section "Deploying Services"

# Ensure Podman machine is running
machine_name=$(state_get_podman_machine "name" "ai-platform")
if ! podman_machine_running "$machine_name"; then
  podman_machine_start "$machine_name"
fi

# Pull pinned container images
ui_step "Pulling pinned container images..."
cd "$PROJECT_ROOT"
compose_cmd=$(podman_compose_cmd)
$compose_cmd pull

# Deploy services in dependency order
ui_step "Starting services in dependency order..."
podman_deploy_staged "postgres" "redis" "clickhouse" "langfuse" "litellm" "caddy"

ui_success "All services deployed"