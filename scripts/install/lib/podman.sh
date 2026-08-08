#!/usr/bin/env bash
# Podman helpers for bootstrap.sh
# Manages Podman installation, machine initialization, and service operations.

set -euo pipefail

# ── Podman Detection ────────────────────────────────────────────────────────

podman_installed() {
  command -v podman >/dev/null 2>&1
}

podman_version() {
  if podman_installed; then
    podman --version 2>/dev/null | head -1
  else
    echo "not installed"
  fi
}

podman_machine_exists() {
  local machine_name="$1"
  podman machine list --format '{{.Name}}' 2>/dev/null | grep -q "^${machine_name}$"
}

podman_machine_running() {
  local machine_name="$1"
  podman machine list --format '{{.Name}} {{.LastUp}}' 2>/dev/null | grep "^${machine_name}" | grep -q "Currently running"
}

# ── Podman Installation ─────────────────────────────────────────────────────

podman_install() {
  if podman_installed; then
    ui_success "Podman $(podman_version)"
    return 0
  fi

  ui_step "Installing Podman via Homebrew..."
  brew install podman

  if ! podman_installed; then
    ui_error "Podman installation failed"
    return 1
  fi

  ui_success "Podman $(podman_version) installed"
  return 0
}

# ── Podman Machine ──────────────────────────────────────────────────────────

podman_machine_init() {
  local machine_name="$1"
  local cpus="$2"
  local memory_mb="$3"
  local disk_gb="$4"

  if podman_machine_exists "$machine_name"; then
    ui_success "Podman machine '$machine_name' already exists"
    return 0
  fi

  ui_step "Initializing Podman machine '$machine_name' (CPUs: $cpus, Memory: ${memory_mb}MB, Disk: ${disk_gb}GB)..."
  podman machine init \
    --cpus "$cpus" \
    --memory "$memory_mb" \
    --disk-size "$disk_gb" \
    --volume "$HOME:$HOME" \
    "$machine_name"

  if ! podman_machine_exists "$machine_name"; then
    ui_error "Podman machine initialization failed"
    return 1
  fi

  ui_success "Podman machine '$machine_name' initialized"
  return 0
}

podman_machine_start() {
  local machine_name="$1"

  if podman_machine_running "$machine_name"; then
    ui_success "Podman machine '$machine_name' is already running"
    return 0
  fi

  ui_step "Starting Podman machine '$machine_name'..."
  podman machine start "$machine_name"

  # Wait for the machine to be ready
  local timeout=60
  local elapsed=0
  while ! podman info >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      ui_error "Podman machine failed to become ready within ${timeout}s"
      return 1
    fi
  done

  ui_success "Podman machine '$machine_name' is running"
  return 0
}

podman_machine_stop() {
  local machine_name="$1"

  if ! podman_machine_running "$machine_name"; then
    ui_success "Podman machine '$machine_name' is already stopped"
    return 0
  fi

  ui_step "Stopping Podman machine '$machine_name'..."
  podman machine stop "$machine_name"
  ui_success "Podman machine '$machine_name' stopped"
  return 0
}

# ── Compose Command Detection ──────────────────────────────────────────────

podman_compose_cmd() {
  # Detect available compose command
  if podman compose version >/dev/null 2>&1; then
    echo "podman compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    echo "podman-compose"
  elif docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  else
    echo "podman compose"
  fi
}

# ── Service Health Wait ─────────────────────────────────────────────────────

podman_wait_service_healthy() {
  local service="$1"
  local timeout="${2:-90}"
  local elapsed=0
  local compose_cmd
  compose_cmd=$(podman_compose_cmd)

  ui_step "Waiting for $service to become healthy..."

  while (( elapsed < timeout )); do
    local status
    status=$($compose_cmd ps "$service" 2>/dev/null | tail -1 | awk '{print $NF}')

    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      ui_success "$service is healthy"
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  ui_error "$service did not become healthy within ${timeout}s"
  return 1
}

# ── Staged Deployment ───────────────────────────────────────────────────────

podman_deploy_staged() {
  local services=("$@")
  local compose_cmd
  compose_cmd=$(podman_compose_cmd)

  for svc in "${services[@]}"; do
    ui_step "Starting $svc..."
    $compose_cmd up -d "$svc"

    if ! podman_wait_service_healthy "$svc"; then
      ui_error "$svc failed health check"
      return 1
    fi
  done

  return 0
}