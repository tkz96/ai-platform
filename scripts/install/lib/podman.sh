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
  # podman machine inspect exits 0 if the machine exists and is registered.
  # Also ensure the returned JSON is a non-empty array.
  local inspect_out
  if inspect_out=$(podman machine inspect "$machine_name" 2>/dev/null); then
    if [[ -n "$inspect_out" && "$inspect_out" != "[]" ]]; then
      return 0
    fi
  fi
  return 1
}

podman_machine_running() {
  local machine_name="$1"
  if ! podman_machine_exists "$machine_name"; then
    return 1
  fi
  local state
  state=$(podman machine inspect "$machine_name" --format '{{.State}}' 2>/dev/null || echo "")
  if [[ "$state" =~ ^[Rr]unning$ ]]; then
    return 0
  fi
  podman machine list --format '{{.Name}} {{.LastUp}}' 2>/dev/null | grep "^${machine_name}" | grep -qi "Currently running"
}

podman_machine_recover_stale() {
  local machine_name="$1"
  ui_warning "Removing stale or corrupted Podman machine '$machine_name'..."
  podman machine rm -f "$machine_name" >/dev/null 2>&1 || true
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
  local cpus="${2:-4}"
  local memory_mb="${3:-8192}"
  local disk_gb="${4:-60}"

  if podman_machine_exists "$machine_name"; then
    ui_success "Podman machine '$machine_name' already exists and is valid"
    return 0
  fi

  ui_step "Initializing Podman machine '$machine_name' (CPUs: $cpus, Memory: ${memory_mb}MB, Disk: ${disk_gb}GB)..."

  local init_output
  if ! init_output=$(podman machine init \
    --cpus "$cpus" \
    --memory "$memory_mb" \
    --disk-size "$disk_gb" \
    --volume "$HOME:$HOME" \
    "$machine_name" 2>&1); then
    # If init reported already exists, check if machine is actually valid
    if echo "$init_output" | grep -qi 'already exists'; then
      if podman_machine_exists "$machine_name"; then
        ui_success "Podman machine '$machine_name' exists and is valid"
        return 0
      fi
      # Stale definition detected: init reported already exists, but machine is not valid
      ui_warning "Podman machine '$machine_name' is in a stale/inconsistent state. Recovering..."
      podman_machine_recover_stale "$machine_name"

      ui_step "Re-initializing Podman machine '$machine_name'..."
      if ! init_output=$(podman machine init \
        --cpus "$cpus" \
        --memory "$memory_mb" \
        --disk-size "$disk_gb" \
        --volume "$HOME:$HOME" \
        "$machine_name" 2>&1); then
        ui_error "Podman machine re-initialization failed: $init_output"
        return 1
      fi
      ui_success "Podman machine '$machine_name' initialized after recovery"
      return 0
    fi
    ui_error "Podman machine initialization failed: $init_output"
    return 1
  fi

  ui_success "Podman machine '$machine_name' initialized"
  return 0
}

podman_machine_start() {
  local machine_name="$1"
  local cpus="${2:-4}"
  local memory_mb="${3:-8192}"
  local disk_gb="${4:-60}"

  if podman_machine_running "$machine_name" && podman info >/dev/null 2>&1; then
    ui_success "Podman machine '$machine_name' is already running and responsive"
    return 0
  fi

  ui_step "Starting Podman machine '$machine_name'..."
  local start_output
  if ! start_output=$(podman machine start "$machine_name" 2>&1); then
    if echo "$start_output" | grep -qiE 'VM does not exist|not found|does not exist|cannot find'; then
      ui_warning "Podman machine start failed ($start_output). Recovering stale machine..."
      podman_machine_recover_stale "$machine_name"
      if ! podman_machine_init "$machine_name" "$cpus" "$memory_mb" "$disk_gb"; then
        ui_error "Failed to re-initialize Podman machine '$machine_name'"
        return 1
      fi
      ui_step "Starting re-created Podman machine '$machine_name'..."
      if ! start_output=$(podman machine start "$machine_name" 2>&1); then
        ui_error "Podman machine start failed after recreation: $start_output"
        return 1
      fi
    else
      ui_error "Podman machine start failed: $start_output"
      return 1
    fi
  fi

  # Wait for the machine to be ready
  local timeout=60
  local elapsed=0
  ui_step "Waiting for Podman service readiness..."
  while ! podman info >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      ui_error "Podman machine failed to become ready within ${timeout}s"
      return 1
    fi
  done

  ui_success "Podman machine '$machine_name' is running and responsive"
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

  ui_step "Waiting for $service to become healthy..."

  while (( elapsed < timeout )); do
    local status
    status=$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service" 2>/dev/null || echo "")

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