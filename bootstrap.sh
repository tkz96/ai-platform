#!/usr/bin/env bash
# AI Platform Bootstrap
# Fresh-machine entry point. Prepares the Mac and deploys the platform.
#
# Usage:
#   ./bootstrap.sh              # Full installation
#   ./bootstrap.sh doctor       # Check machine readiness
#   ./bootstrap.sh start        # Start platform services
#   ./bootstrap.sh stop         # Stop platform services
#   ./bootstrap.sh restart      # Restart platform services
#   ./bootstrap.sh status       # Show service status
#   ./bootstrap.sh update       # Update platform (with review)
#   ./bootstrap.sh verify       # Run health checks
#   ./bootstrap.sh logs         # Tail service logs
#   ./bootstrap.sh backup       # Create backup
#   ./bootstrap.sh restore      # Restore from backup
#   ./bootstrap.sh destroy      # Remove all containers and volumes

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$SCRIPT_DIR"
INSTALL_DIR="$SCRIPT_DIR/scripts/install"
LIB_DIR="$INSTALL_DIR/lib"

# ── Source Libraries ────────────────────────────────────────────────────────

source "$LIB_DIR/ui.sh"
source "$LIB_DIR/state.sh"
source "$LIB_DIR/ports.sh"
source "$LIB_DIR/podman.sh"

# ── Version ─────────────────────────────────────────────────────────────────

BOOTSTRAP_VERSION="0.1.0"

# ── Helpers ─────────────────────────────────────────────────────────────────

get_platform_domain() {
  # Read domain from platform.yaml using yq — single source of truth
  yq -r '.domain // "localhost"' "$PROJECT_ROOT/platform.yaml" 2>/dev/null || echo "localhost"
}

# ── Dependency Check ───────────────────────────────────────────────────────

run_dependency_check() {
  ui_section "Dependency Check"

  local missing=()

  ui_dependency_check "Git" "command -v git" "git --version | awk '{print \$3}'" || missing+=("git")
  ui_dependency_check "Homebrew" "command -v brew" "brew --version | head -1 | awk '{print \$2}'" || missing+=("brew")
  ui_dependency_check "Python 3.12+" "command -v python3" "python3 --version | awk '{print \$2}'" || missing+=("python3")
  ui_dependency_check "uv" "command -v uv" "uv --version | awk '{print \$2}'" || missing+=("uv")
  ui_dependency_check "Podman" "command -v podman" "podman --version | head -1" || missing+=("podman")
  ui_dependency_check "jq" "command -v jq" "jq --version" || missing+=("jq")
  ui_dependency_check "yq" "command -v yq" "yq --version | head -1" || missing+=("yq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    ui_warning "The following tools are missing:"
    for tool in "${missing[@]}"; do
      echo -e "    ${RED}${SYM_FAIL}${RESET} $tool"
    done
    echo
    if ui_confirm "Install missing tools automatically?"; then
      return 1  # Signal that install phases should run
    else
      ui_fatal "Cannot continue without required tools."
    fi
  else
    echo
    ui_success "All dependencies are installed."
    return 0
  fi
}

# ── Help ────────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
AI Platform Bootstrap v${BOOTSTRAP_VERSION}

Usage:
  ./bootstrap.sh [command]

Commands:
  install     Full installation (default)
  doctor      Check machine readiness
  start       Start platform services
  stop        Stop platform services
  restart     Restart platform services
  status      Show service status
  update      Update platform (with review)
  verify      Run health checks
  logs        Tail service logs
  backup      Create backup
  restore     Restore from backup
  destroy     Remove all containers and volumes
  help        Show this help

Examples:
  ./bootstrap.sh          # Install on a fresh Mac
  ./bootstrap.sh doctor   # Check if machine is ready
  ./bootstrap.sh status   # Check service health
EOF
}

# ── Install ─────────────────────────────────────────────────────────────────

run_install() {
  # Show ASCII art splash
  ui_splash

  # Show system info and confirm
  ui_system_info

  if ! ui_confirm "This installer will configure this Mac as an AI Platform server. Continue?"; then
    ui_info "Installation cancelled."
    exit 0
  fi

  # Initialize state
  state_init

  # Run install phases in order
  local phases=(
    "check-macos:00-check-macos.sh"
    "homebrew:01-homebrew.sh"
    "tools:02-tools.sh"
    "python:03-python.sh"
    "uv:04-uv.sh"
    "podman:05-podman.sh"
    "ports:06-ports.sh"
    "secrets:07-secrets.sh"
    "render:08-render.sh"
    "deploy:09-deploy.sh"
    "verify:10-verify.sh"
  )

  for entry in "${phases[@]}"; do
    local phase_name="${entry%%:*}"
    local phase_script="${entry##*:}"

    if ! state_run_phase "$phase_name" "$INSTALL_DIR/$phase_script"; then
      state_rollback "$phase_name"
      ui_fatal "Installation failed at phase: $phase_name"
    fi
  done

  # Final banner — read domain from platform.yaml
  local domain http_port https_port
  domain=$(get_platform_domain)
  http_port=$(state_get_port "caddy" "8080")
  https_port=$(state_get_port "caddy" "8443")
  ui_done_banner "$domain" "$http_port" "$https_port"

  ui_success "Installation complete!"
  echo
  ui_info "Next steps:"
  echo
  echo -e "  ${CYAN}./bootstrap.sh status${RESET}   — Check service health"
  echo -e "  ${CYAN}./bootstrap.sh logs${RESET}     — View service logs"
  echo -e "  ${CYAN}./bootstrap.sh update${RESET}   — Update the platform"
  echo
}

# ── Doctor ──────────────────────────────────────────────────────────────────

run_doctor() {
  ui_header "AI Platform Doctor"

  local all_ok=true

  # Delegate system checks to the install phase script
  ui_section "System Checks"
  if bash "$INSTALL_DIR/00-check-macos.sh" 2>&1; then
    ui_success "System checks passed"
  else
    ui_error "System checks failed"
    all_ok=false
  fi

  ui_section "Tool Checks"

  # Git
  if command -v git >/dev/null 2>&1; then
    ui_success "Git $(git --version | awk '{print $3}')"
  else
    ui_error "Git not installed"
    all_ok=false
  fi

  # Homebrew
  if command -v brew >/dev/null 2>&1; then
    ui_success "Homebrew $(brew --version | head -1 | awk '{print $2}')"
  else
    ui_error "Homebrew not installed"
    all_ok=false
  fi

  # Python
  if command -v python3 >/dev/null 2>&1; then
    local py_version
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    if python3 -c "import sys; exit(0 if sys.version_info >= (3,12) else 1)" 2>/dev/null; then
      ui_success "Python $py_version (>= 3.12)"
    else
      ui_error "Python $py_version (requires >= 3.12)"
      all_ok=false
    fi
  else
    ui_error "Python not installed"
    all_ok=false
  fi

  # uv
  if command -v uv >/dev/null 2>&1; then
    ui_success "uv $(uv --version | awk '{print $2}')"
  else
    ui_error "uv not installed"
    all_ok=false
  fi

  # Podman
  if podman_installed; then
    ui_success "Podman $(podman_version)"
  else
    ui_error "Podman not installed"
    all_ok=false
  fi

  # Podman machine
  local machine_name
  machine_name=$(state_get_podman_machine "name" "ai-platform")
  if podman_machine_exists "$machine_name"; then
    if podman_machine_running "$machine_name"; then
      ui_success "Podman machine '$machine_name' is running"
    else
      ui_warning "Podman machine '$machine_name' exists but is not running"
    fi
  else
    ui_warning "Podman machine '$machine_name' does not exist"
  fi

  ui_section "Port Checks"

  # Read ports from service manifests — single source of truth
  local port_entries
  port_entries=$(port_read_from_manifests "$PROJECT_ROOT/services")

  if [[ -n "$port_entries" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local service="${entry%%:*}"
      local port="${entry##*:}"

      if port_available "$port"; then
        ui_success "$service: port $port available"
      else
        ui_warning "$service: port $port in use"
      fi
    done <<< "$port_entries"
  else
    ui_warning "No service manifests found"
  fi

  ui_section "State Checks"

  # Configuration
  if [[ -f "$PROJECT_ROOT/platform.yaml" ]]; then
    ui_success "platform.yaml found"
  else
    ui_error "platform.yaml missing"
    all_ok=false
  fi

  # Secrets
  if [[ -f "$PROJECT_ROOT/.env" ]]; then
    ui_success ".env exists"
  else
    ui_warning ".env not found — run ./bootstrap.sh to generate"
  fi

  # Services
  local compose_cmd
  compose_cmd=$(podman_compose_cmd)
  if $compose_cmd ps >/dev/null 2>&1; then
    local running_count
    running_count=$($compose_cmd ps 2>/dev/null | grep -c "Up" || echo "0")
    if (( running_count > 0 )); then
      ui_success "$running_count services running"
    else
      ui_warning "No services running"
    fi
  else
    ui_warning "Cannot query services — Podman not ready"
  fi

  echo
  if $all_ok; then
    ui_success "All checks passed. Platform is ready."
    return 0
  else
    ui_error "Some checks failed. Run ./bootstrap.sh to fix."
    return 1
  fi
}

# ── Start / Stop / Restart ─────────────────────────────────────────────────

run_start() {
  ui_header "Starting AI Platform"

  # Ensure Podman machine is running
  local machine_name
  machine_name=$(state_get_podman_machine "name" "ai-platform")
  if ! podman_machine_running "$machine_name"; then
    podman_machine_start "$machine_name"
  fi

  local compose_cmd
  compose_cmd=$(podman_compose_cmd)
  $compose_cmd up -d
  ui_success "Platform started"
}

run_stop() {
  ui_header "Stopping AI Platform"
  local compose_cmd
  compose_cmd=$(podman_compose_cmd)
  $compose_cmd down
  ui_success "Platform stopped"
}

run_restart() {
  ui_header "Restarting AI Platform"
  run_stop
  run_start
}

# ── Status ──────────────────────────────────────────────────────────────────

run_status() {
  ui_header "AI Platform Status"

  # Validate config
  ui_step "Validating configuration..."
  if (cd "$PROJECT_ROOT" && uv run python bootstrap.py status); then
    ui_success "Configuration valid"
  else
    ui_error "Configuration validation failed"
    return 1
  fi
}

# ── Update ──────────────────────────────────────────────────────────────────

run_update() {
  ui_header "AI Platform Update"

  # Check for uncommitted changes
  if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]]; then
    ui_warning "You have uncommitted changes in the repository."
    if ! ui_confirm "Continue anyway?" "N"; then
      ui_info "Update cancelled."
      return 1
    fi
  fi

  # Fetch latest
  ui_step "Fetching latest changes..."
  git -C "$PROJECT_ROOT" fetch origin main

  local current_hash target_hash
  current_hash=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
  target_hash=$(git -C "$PROJECT_ROOT" rev-parse origin/main)

  if [[ "$current_hash" == "$target_hash" ]]; then
    ui_success "Already up to date."
    return 0
  fi

  # Show changes
  ui_section "Changes since current version"
  git -C "$PROJECT_ROOT" log --oneline "$current_hash..$target_hash" | head -20

  # Show version changes
  ui_section "Version Changes"
  local current_versions new_versions
  current_versions=$(git -C "$PROJECT_ROOT" show "HEAD:versions.yaml" 2>/dev/null || echo "")
  new_versions=$(git -C "$PROJECT_ROOT" show "origin/main:versions.yaml" 2>/dev/null || echo "")

  if [[ "$current_versions" != "$new_versions" ]]; then
    diff <(echo "$current_versions") <(echo "$new_versions") || true
  else
    ui_info "No version changes."
  fi

  echo
  if ! ui_confirm "Proceed with update?" "N"; then
    ui_info "Update cancelled."
    return 1
  fi

  # Backup BEFORE pulling — so we can restore if anything fails
  ui_step "Creating pre-update backup..."
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py backup)

  # Pull
  ui_step "Pulling latest code..."
  git -C "$PROJECT_ROOT" pull origin main

  # Render
  ui_step "Rendering configuration..."
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py render)

  # Deploy
  ui_step "Redeploying services..."
  local compose_cmd
  compose_cmd=$(podman_compose_cmd)
  $compose_cmd up -d

  # Verify
  ui_step "Verifying services..."
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py verify)

  ui_success "Update complete!"
}

# ── Verify ──────────────────────────────────────────────────────────────────

run_verify() {
  ui_header "AI Platform Verification"
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py verify)
}

# ── Logs ───────────────────────────────────────────────────────────────────

run_logs() {
  local service="${1:-}"
  local compose_cmd
  compose_cmd=$(podman_compose_cmd)
  if [[ -n "$service" ]]; then
    $compose_cmd logs -f "$service"
  else
    $compose_cmd logs -f
  fi
}

# ── Backup / Restore ───────────────────────────────────────────────────────

run_backup() {
  ui_header "AI Platform Backup"
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py backup)
}

run_restore() {
  local src="${1:-}"
  if [[ -z "$src" ]]; then
    ui_error "Usage: ./bootstrap.sh restore --src <backup-file>"
    return 1
  fi
  ui_header "AI Platform Restore"
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py restore --src "$src")
}

# ── Destroy ────────────────────────────────────────────────────────────────

run_destroy() {
  ui_header "AI Platform Destroy"

  ui_warning "This will remove all containers, networks, and volumes."
  ui_warning "This action cannot be undone."

  if ! ui_confirm "Are you absolutely sure?" "N"; then
    ui_info "Destroy cancelled."
    return 0
  fi

  local compose_cmd
  compose_cmd=$(podman_compose_cmd)
  $compose_cmd down -v

  if ui_confirm "Also remove the Podman machine?" "N"; then
    local machine_name
    machine_name=$(state_get_podman_machine "name" "ai-platform")
    if podman_machine_exists "$machine_name"; then
      podman machine rm -f "$machine_name"
      ui_success "Podman machine '$machine_name' removed"
    fi
  fi

  if ui_confirm "Clear install state?" "N"; then
    state_reset
  fi

  ui_success "Platform destroyed"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  local command="${1:-install}"
  shift 2>/dev/null || true

  case "$command" in
    install)   run_install ;;
    doctor)    run_doctor ;;
    start)     run_start ;;
    stop)      run_stop ;;
    restart)   run_restart ;;
    status)    run_status ;;
    update)    run_update ;;
    verify)    run_verify ;;
    logs)      run_logs "$@" ;;
    backup)    run_backup ;;
    restore)   run_restore "$@" ;;
    destroy)   run_destroy ;;
    help|-h|--help) show_help ;;
    *)
      ui_error "Unknown command: $command"
      echo
      show_help
      exit 1
      ;;
  esac
}

main "$@"