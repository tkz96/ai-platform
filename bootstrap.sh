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
#   ./bootstrap.sh restore           # Restore from backup
#   ./bootstrap.sh destroy           # Remove all containers and volumes
#   ./bootstrap.sh connect-inference # Configure & verify inference PC connection

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$SCRIPT_DIR"
INSTALL_DIR="$SCRIPT_DIR/scripts/install"
LIB_DIR="$INSTALL_DIR/lib"

# ── Environment Setup ───────────────────────────────────────────────────────

if [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
if [[ -d "$HOME/.local/bin" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# ── Source Libraries ────────────────────────────────────────────────────────

source "$LIB_DIR/ui.sh"
source "$LIB_DIR/state.sh"
source "$LIB_DIR/ports.sh"
source "$LIB_DIR/podman.sh"
source "$LIB_DIR/networking.sh"

# ── Version ─────────────────────────────────────────────────────────────────

BOOTSTRAP_VERSION="0.1.0"

# ── Helpers ─────────────────────────────────────────────────────────────────

get_platform_domain() {
  # Read domain from platform.yaml using yq — single source of truth
  yq '.domain // "localhost"' "$PROJECT_ROOT/platform.yaml" 2>/dev/null || echo "localhost"
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
      ui_quit_prompt "Cannot continue without required tools." "Install the missing tools listed above, then re-run ./bootstrap.sh"
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
  backup              Create backup
  restore             Restore from backup
  destroy             Remove all containers and volumes
  reset               Full factory reset (nuke VM, containers, state, and start fresh)
  connect-inference   Configure, connect & verify the inference PC
  help                Show this help

Examples:
  ./bootstrap.sh                    # Install on a fresh Mac
  ./bootstrap.sh reset              # Wipe and perform clean factory reset
  ./bootstrap.sh doctor             # Check if machine is ready
  ./bootstrap.sh status             # Check service health
  ./bootstrap.sh connect-inference  # Hook up the inference PC
EOF
}

# ── Install ─────────────────────────────────────────────────────────────────

run_install() {
  # Show ASCII art splash
  ui_splash

  # Show system info
  ui_system_info

  # Prominent early enrollment notice
  echo
  echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${BOLD}${CYAN}AI Platform — Linux Node Enrollment Notice${RESET}"
  echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  Every fresh Linux inference PC must:"
  echo -e "    1. Be running a fresh Ubuntu installation"
  echo -e "    2. Be physically connected to this Mac directly or via switch"
  echo -e "    3. Run the one-time enrollment command when prompted:"
  echo -e "       ${DIM}wget -q http://10.42.0.1:8765/node-enroll.sh -O node-enroll.sh${RESET}"
  echo -e "       ${DIM}chmod +x node-enroll.sh && sudo ./node-enroll.sh --token <TOKEN>${RESET}"
  echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo

  if ! ui_confirm "This installer will configure this Mac as an AI Platform server. Continue?"; then
    ui_info "Installation cancelled."
    exit 0
  fi

  # Initialize state
  state_init

  # Run install phases in order:
  # secrets runs before networking so cluster SSH keys and session token are ready
  local phases=(
    "check-macos:00-check-macos.sh"
    "homebrew:01-homebrew.sh"
    "tools:02-tools.sh"
    "python:03-python.sh"
    "uv:04-uv.sh"
    "podman:05-podman.sh"
    "ports:06-ports.sh"
    "secrets:07-secrets.sh"
    "networking:06a-networking.sh"
    "render:08-render.sh"
    "deploy:09-deploy.sh"
    "verify:10-verify.sh"
  )

  for entry in "${phases[@]}"; do
    local phase_name="${entry%%:*}"
    local phase_script="${entry##*:}"

    if ! state_run_phase "$phase_name" "$INSTALL_DIR/$phase_script"; then
      state_rollback "$phase_name"
      ui_quit_prompt "Installation failed at phase: $phase_name" "Fix the issue above, then re-run: ./bootstrap.sh"
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
    running_count=$($compose_cmd ps 2>/dev/null | grep -c "Up" || true)
    running_count="${running_count//[^0-9]/}"
    [[ -z "$running_count" ]] && running_count=0
    if (( running_count > 0 )); then
      ui_success "$running_count services running"
    else
      ui_warning "No services running"
    fi
  else
    ui_warning "Cannot query services — Podman not ready"
  fi

  ui_section "Inference Node & Network Topology"

  local inf_host="10.42.0.2"
  local inf_port="8080"
  local inf_endpoint="/health"
  if [[ -f "$PROJECT_ROOT/.env" ]]; then
    inf_host=$(grep '^INFERENCE_HOST=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d= -f2- || echo "10.42.0.2")
    inf_port=$(grep '^INFERENCE_PORT=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d= -f2- || echo "8080")
    inf_endpoint=$(grep '^INFERENCE_HEALTH_ENDPOINT=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d= -f2- || echo "/health")
    [[ -z "$inf_host" ]] && inf_host="10.42.0.2"
    [[ -z "$inf_port" ]] && inf_port="8080"
    [[ -z "$inf_endpoint" ]] && inf_endpoint="/health"
  fi

  # Check physical Ethernet candidates
  local eth_candidates
  eth_candidates=$(list_physical_ethernet_candidates 2>/dev/null || true)
  if [[ -n "$eth_candidates" ]]; then
    local active_found=false
    while IFS= read -r cand; do
      [[ -z "$cand" ]] && continue
      local c_dev
      c_dev=$(echo "$cand" | cut -d'|' -f2)
      if interface_has_link "$c_dev"; then
        active_found=true
        local c_ip
        c_ip=$(interface_get_ip "$c_dev")
        ui_success "Mac Ethernet ($c_dev): carrier ACTIVE (IP: ${c_ip:-none})"
      fi
    done <<< "$eth_candidates"
    if ! $active_found; then
      ui_warning "Mac Ethernet: physical carrier DOWN on candidate interfaces"
    fi
  else
    ui_warning "Mac Ethernet: no physical Ethernet ports found"
  fi

  # Check node reachability (ping)
  if ping -c 1 -W 2 "$inf_host" >/dev/null 2>&1; then
    ui_success "Inference node ($inf_host): REACHABLE"
  else
    ui_warning "Inference node ($inf_host): UNREACHABLE via ping"
  fi

  # Check Mac Host TCP to port
  if check_host_tcp_connection "$inf_host" "$inf_port"; then
    ui_success "Inference TCP ($inf_host:$inf_port): OPEN"
  else
    ui_warning "Inference TCP ($inf_host:$inf_port): CLOSED"
  fi

  # Check Mac Host HTTP Health
  if check_host_http_health "$inf_host" "$inf_port" "$inf_endpoint"; then
    ui_success "Inference HTTP API ($inf_host:$inf_port$inf_endpoint): HEALTHY"
  else
    ui_warning "Inference HTTP API ($inf_host:$inf_port$inf_endpoint): PENDING/UNHEALTHY"
  fi

  # Check Podman VM reachability if podman is running
  if podman info >/dev/null 2>&1; then
    if check_podman_vm_health "$inf_host" "$inf_port" "$inf_endpoint"; then
      ui_success "Podman VM → Inference node: HEALTHY"
    else
      ui_warning "Podman VM → Inference node: UNREACHABLE"
    fi
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

# ── Connect Inference ─────────────────────────────────────────────────────

run_connect_inference() {
  bash "$INSTALL_DIR/06a-networking.sh"
}

# ── Web UI ──────────────────────────────────────────────────────────────────

run_ui() {
  ui_header "AI Platform Control Plane Web UI"
  local target_port="${1:-8888}"

  if port_is_dashboard "$target_port"; then
    ui_success "AI Platform Web Dashboard is already active at http://127.0.0.1:${target_port}"
    open "http://127.0.0.1:${target_port}" 2>/dev/null || true
    return 0
  fi

  if ! port_available "$target_port"; then
    local alt_port
    alt_port=$(port_find_available "$target_port")
    if [[ -n "$alt_port" ]]; then
      ui_warning "Port $target_port is in use. Switching Web UI to http://127.0.0.1:${alt_port}"
      target_port="$alt_port"
    fi
  fi

  ui_info "Starting Web UI server on http://127.0.0.1:${target_port}..."
  (sleep 1.2 && open "http://127.0.0.1:${target_port}" 2>/dev/null || true) &
  (cd "$PROJECT_ROOT" && uv run uvicorn ai_platform.web.app:app --host 127.0.0.1 --port "$target_port")
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

# ── Factory Reset ──────────────────────────────────────────────────────────

run_factory_reset() {
  ui_header "AI Platform Nuclear Factory Reset"

  echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${RED}${BOLD}🚨  CRITICAL WARNING: NUCLEAR FACTORY RESET  🚨${RESET}"
  echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${RED}${BOLD}THIS IS A NUCLEAR RESET. THIS ACTION CANNOT BE REVERSED.${RESET}"
  echo -e "  ${RED}${BOLD}ALL OF YOUR DATA MUST BE BACKED UP BEFORE PROCEEDING.${RESET}"
  echo
  echo -e "  ${YELLOW}${BOLD}The following will be completely and permanently destroyed:${RESET}"
  echo -e "    ${RED}${SYM_DOT}${RESET} Active dashboard and background orchestrator processes"
  echo -e "    ${RED}${SYM_DOT}${RESET} All Podman containers, database storage, and persistent volumes"
  echo -e "    ${RED}${SYM_DOT}${RESET} The entire 'ai-platform' Podman VM and all system connection sockets"
  echo -e "    ${RED}${SYM_DOT}${RESET} All local cluster secrets, cryptographic keys, and .env files"
  echo -e "    ${RED}${SYM_DOT}${RESET} All runtime node enrollments and network packet-forwarding rules"
  echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo

  if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    ui_warning "Forced nuclear reset requested via flag — bypassing interactive confirmations."
  elif is_noninteractive; then
    ui_error "Nuclear factory reset requires interactive confirmation or --force."
    return 1
  else
    # ── Gate 1: Initial y/N Confirmation ──
    if ! ui_confirm "Are you ABSOLUTELY sure you want to proceed with this NUCLEAR FACTORY RESET?" "N"; then
      ui_info "Factory reset aborted by user."
      return 1
    fi

    # ── Gate 2: Explicit Typed Confirmation Phrase ──
    echo
    echo -e "  ${BOLD}To prevent accidental deletion, type ${RED}NUCLEAR RESET${RESET}${BOLD} to confirm:${RESET}"
    printf "  > "
    local confirm_text=""
    read -r confirm_text
    if [[ "$confirm_text" != "NUCLEAR RESET" ]]; then
      ui_warning "Confirmation text mismatch ('$confirm_text' != 'NUCLEAR RESET'). Factory reset aborted."
      return 1
    fi

    # ── Gate 3: Administrator Password Verification ──
    echo
    ui_step "Administrative privilege verification required. Please authenticate with your password:"
    sudo -k
    if ! sudo -v; then
      ui_error "Administrative password verification failed. Factory reset aborted."
      return 1
    fi
    ui_success "Administrative authentication verified"

    # ── Gate 4: Final y/N Confirmation ──
    echo
    if ! ui_confirm "FINAL CONFIRMATION: Irrevocably destroy all platform data, VM, and volumes now?" "N"; then
      ui_info "Factory reset aborted at final confirmation."
      return 1
    fi
  fi

  # 1. Terminate any running web dashboard processes on port 8888, 8889, 8765
  ui_step "Stopping active dashboard and orchestrator processes..."
  local pids
  pids=$(lsof -ti :8888,8889,8765 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -15 "$pid" 2>/dev/null || true
    done <<< "$pids"
    sleep 1
    pids=$(lsof -ti :8888,8889,8765 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        kill -9 "$pid" 2>/dev/null || true
      done <<< "$pids"
    fi
  fi

  # 2. Stop and remove containers and volumes
  ui_step "Tearing down Podman containers and volumes..."
  if command -v podman >/dev/null 2>&1; then
    if [[ -f "$PROJECT_ROOT/compose.yaml" ]]; then
      local compose_cmd
      compose_cmd=$(podman_compose_cmd 2>/dev/null || echo "")
      if [[ -n "$compose_cmd" ]]; then
        (cd "$PROJECT_ROOT" && $compose_cmd down -v --remove-orphans >/dev/null 2>&1) || true
      fi
    fi
    local containers
    containers=$(podman ps -aq --filter "name=postgres|redis|clickhouse|langfuse|litellm|caddy" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
      podman rm -f $containers >/dev/null 2>&1 || true
    fi
  fi

  # 3. Destroy Podman machine and clean system connections
  ui_step "Destroying Podman VM and cleaning connections..."
  local machine_name="ai-platform"
  podman system connection rm "$machine_name" >/dev/null 2>&1 || true
  podman system connection rm "${machine_name}-root" >/dev/null 2>&1 || true
  if podman_machine_exists "$machine_name" 2>/dev/null; then
    podman machine rm -f "$machine_name" >/dev/null 2>&1 || true
  fi

  # 4. Tear down host networking
  ui_step "Resetting host networking and DHCP services..."
  stop_mac_dhcp_server 2>/dev/null || true
  disable_mac_nat_gateway 2>/dev/null || true

  # 5. Clean local state, generated artifacts, and secrets
  ui_step "Wiping local runtime state and generated configurations..."
  rm -rf "$PROJECT_ROOT/.install-state" \
         "$PROJECT_ROOT/state" \
         "$PROJECT_ROOT/secrets" \
         "$PROJECT_ROOT/.env" \
         "$PROJECT_ROOT/configs" \
         "$PROJECT_ROOT/compose.yaml"
  state_reset 2>/dev/null || true

  echo
  ui_success "Factory reset completed successfully — all platform data and containers destroyed"
  return 0
}

# ── Web Dashboard Launch & Sudo Session ───────────────────────────────────────

run_bootstrap_default() {
  ui_splash
  ui_header "AI Platform Setup & Control Deck"

  # 1. Ensure minimal prerequisites (00-check-macos through 06-ports)
  ui_section "Host Prerequisites Validation"
  
  local minimal_phases=(
    "check-macos:00-check-macos.sh"
    "homebrew:01-homebrew.sh"
    "tools:02-tools.sh"
    "python:03-python.sh"
    "uv:04-uv.sh"
    "podman:05-podman.sh"
    "ports:06-ports.sh"
  )

  # Check if minimal dependencies are already satisfied
  local all_deps_met=true
  if ! command -v git >/dev/null 2>&1 || \
     ! command -v brew >/dev/null 2>&1 || \
     ! command -v python3 >/dev/null 2>&1 || \
     ! command -v uv >/dev/null 2>&1 || \
     ! command -v podman >/dev/null 2>&1 || \
     ! command -v jq >/dev/null 2>&1 || \
     ! command -v yq >/dev/null 2>&1; then
    all_deps_met=false
  fi

  if $all_deps_met; then
    ui_success "Host prerequisites verified (Git, Homebrew, Python, uv, Podman, jq, yq)"
  else
    ui_info "Installing missing host prerequisites..."
    state_init
    for entry in "${minimal_phases[@]}"; do
      local phase_name="${entry%%:*}"
      local phase_script="${entry##*:}"
      if ! state_run_phase "$phase_name" "$INSTALL_DIR/$phase_script"; then
        ui_quit_prompt "Prerequisite setup failed at: $phase_name" "Resolve the issue and re-run ./bootstrap.sh"
      fi
    done
  fi

  # 2. Acquire and keep alive sudo credentials for dashboard session
  echo
  ui_step "Authenticating administrative privileges for platform networking..."
  if sudo -v; then
    # Keep sudo session alive in background until bootstrap exits
    while true; do sudo -n -v; sleep 180; done 2>/dev/null &
    local sudo_keeper_pid=$!
    trap 'kill "$sudo_keeper_pid" 2>/dev/null || true' EXIT INT TERM
    ui_success "Administrative session active"
  else
    ui_warning "Sudo authentication skipped — networking phase will prompt if required"
  fi

  # 3. Synchronize python dependencies with interactive self-healing
  ui_step "Verifying platform Python dependencies via uv..."
  while true; do
    local sync_output
    if sync_output=$(cd "$PROJECT_ROOT" && uv sync 2>&1) && \
       (cd "$PROJECT_ROOT" && uv run python -c "import uvicorn, fastapi" >/dev/null 2>&1 && uv run which uvicorn >/dev/null 2>&1); then
      ui_success "Python environment ready (FastAPI & Uvicorn verified)"
      break
    else
      ui_warning "Python dependency validation failed."
      local venv_choice
      venv_choice=$(ui_recovery_menu "Python Virtual Environment" "Missing required packages or corrupted virtualenv" \
        "Refresh & Re-sync dependencies (uv sync --refresh)" \
        "Rebuild .venv in-place (rm -rf .venv && uv venv && uv sync)" \
        "Retry verification")

      case "$venv_choice" in
        0)
          ui_info "Re-syncing dependencies..."
          (cd "$PROJECT_ROOT" && uv sync --refresh) || true
          ;;
        1)
          ui_info "Rebuilding virtual environment from scratch..."
          (cd "$PROJECT_ROOT" && rm -rf .venv && uv venv && uv sync) || true
          ;;
        2)
          ui_info "Retrying verification..."
          ;;
      esac
    fi
  done

  # 4. Interactive Port Collision Handler & Dashboard Detection
  local target_port=8888
  if port_is_dashboard "$target_port"; then
    if is_noninteractive; then
      ui_success "AI Platform Web Dashboard is already running at http://127.0.0.1:${target_port}"
      (sleep 0.5 && open "http://127.0.0.1:${target_port}" 2>/dev/null || true) &
      return 0
    fi

    echo
    ui_warning "An active AI Platform Web Dashboard was detected on port ${target_port}."
    local dashboard_choice
    dashboard_choice=$(ui_recovery_menu "Existing Dashboard Detected" "A running dashboard was found at http://127.0.0.1:${target_port}" \
      "Open existing dashboard in browser (http://127.0.0.1:${target_port})" \
      "Perform Factory Reset & Start Fresh (kill old stack, wipe VM/state, restart fresh)" \
      "Launch on a new available port" \
      "Cancel")

    case "$dashboard_choice" in
      0)
        ui_info "Opening existing dashboard..."
        (sleep 0.5 && open "http://127.0.0.1:${target_port}" 2>/dev/null || true) &
        return 0
        ;;
      1)
        ui_info "Initiating Factory Reset..."
        if run_factory_reset; then
          ui_step "Restarting setup sequence from fresh state..."
          exec "$PROJECT_ROOT/bootstrap.sh"
        else
          ui_warning "Factory reset aborted. Returning to setup menu..."
        fi
        ;;
      2)
        local alt_port
        alt_port=$(port_find_available $((target_port + 1)))
        if [[ -n "$alt_port" ]]; then
          ui_info "Switching Web UI to port $alt_port..."
          target_port="$alt_port"
        else
          ui_error "Could not find available port for Web Dashboard"
          return 1
        fi
        ;;
      3)
        ui_info "Exiting at user request."
        return 0
        ;;
    esac
  fi

  while ! port_available "$target_port"; do
    ui_warning "Port $target_port is currently in use."
    local occupant_pid
    occupant_pid=$(lsof -ti :"$target_port" 2>/dev/null | head -1 || echo "")

    if is_noninteractive; then
      local next_port
      next_port=$(port_find_available $((target_port + 1)))
      if [[ -n "$next_port" ]]; then
        ui_info "Non-interactive mode: switching to available port $next_port"
        target_port="$next_port"
        break
      else
        ui_error "Could not find available port for Web Dashboard"
        return 1
      fi
    fi

    local port_choice
    if [[ -n "$occupant_pid" ]]; then
      local occupant_cmd
      occupant_cmd=$(ps -p "$occupant_pid" -o comm= 2>/dev/null || echo "unknown")
      ui_info "Occupied by process PID $occupant_pid ($occupant_cmd)"

      port_choice=$(ui_recovery_menu "Port Collision ($target_port)" "Port $target_port is already bound by PID $occupant_pid ($occupant_cmd)" \
        "Bind Web UI to next available port ($((target_port + 1)))" \
        "Terminate process $occupant_pid and use port $target_port" \
        "Retry port $target_port")

      case "$port_choice" in
        0)
          target_port=$((target_port + 1))
          ui_info "Switched target port to $target_port"
          ;;
        1)
          ui_info "Terminating process $occupant_pid..."
          kill -15 "$occupant_pid" 2>/dev/null || true
          sleep 1
          if ! port_available "$target_port"; then
            kill -9 "$occupant_pid" 2>/dev/null || true
            sleep 1
          fi
          ;;
        2)
          ui_info "Retrying port $target_port..."
          ;;
      esac
    else
      target_port=$((target_port + 1))
      ui_info "Switched target port to $target_port"
    fi
  done

  # 5. Launch web dashboard with retry loop
  while true; do
    echo
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${BOLD}${CYAN}AI Platform Web Dashboard Launching${RESET}"
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Opening web deck: ${BOLD}${GREEN}http://127.0.0.1:${target_port}${RESET}"
    echo -e "  Use the ${BOLD}Setup & Provision${RESET} tab to configure networking,"
    echo -e "  generate security keys, and deploy all control plane services."
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo

    # Auto-open browser in background
    (sleep 1.2 && open "http://127.0.0.1:${target_port}" 2>/dev/null || true) &

    # Start FastAPI Uvicorn server
    if (cd "$PROJECT_ROOT" && uv run uvicorn ai_platform.web.app:app --host 127.0.0.1 --port "$target_port"); then
      ui_info "Web UI server shut down normally."
      break
    else
      if is_noninteractive; then
        ui_error "Uvicorn server on port $target_port failed to start."
        return 1
      fi

      local ui_choice
      ui_choice=$(ui_recovery_menu "Web UI Server Error" "Uvicorn server exited unexpectedly" \
        "Restart Web UI server on http://127.0.0.1:${target_port}" \
        "Re-bind to a different port" \
        "Switch to headless CLI installation mode")

      case "$ui_choice" in
        0)
          ui_info "Restarting Web UI..."
          ;;
        1)
          target_port=$((target_port + 1))
          ui_info "Switching to port $target_port..."
          ;;
        2)
          ui_info "Switching to headless CLI setup mode..."
          run_install
          break
          ;;
      esac
    fi
  done
}



# ── Main ────────────────────────────────────────────────────────────────────

main() {
  local command="${1:-default}"
  shift 2>/dev/null || true

  case "$command" in
    default|up)         run_bootstrap_default ;;
    install)            
      if [[ "${1:-}" == "--headless" || "${1:-}" == "-h" ]]; then
        run_install
      else
        run_bootstrap_default
      fi
      ;;
    headless)           run_install ;;
    doctor)             run_doctor ;;
    start)              run_start ;;
    stop)               run_stop ;;
    restart)            run_restart ;;
    status)             run_status ;;
    update)             run_update ;;
    verify)             run_verify ;;
    logs)               run_logs "$@" ;;
    backup)             run_backup ;;
    restore)            run_restore "$@" ;;
    destroy)            run_destroy ;;
    reset|factory-reset|--reset)
      run_factory_reset "$@"
      ;;
    connect-inference)  run_connect_inference ;;
    ui)                 run_ui ;;
    help|-h|--help)     show_help ;;
    *)
      ui_error "Unknown command: $command"
      echo
      show_help
      exit 1
      ;;
  esac
}

main "$@"