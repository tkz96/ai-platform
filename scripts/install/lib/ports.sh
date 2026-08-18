#!/usr/bin/env bash
# Port checking utilities for bootstrap.sh
# Checks port availability and resolves conflicts interactively.
# Ports are read from services/*.yaml using yq — single source of truth.

set -euo pipefail

# Ensure Homebrew & local binaries are in PATH
if [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Ensure UI library is sourced
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v ui_error >/dev/null 2>&1; then
  [[ -f "$LIB_DIR/ui.sh" ]] && source "$LIB_DIR/ui.sh"
fi

# ── Port Availability ───────────────────────────────────────────────────────

port_available() {
  local port="$1"
  local info
  info=$(lsof -i ":$port" -sTCP:LISTEN -P -n 2>/dev/null | tail -1)
  if [[ -z "$info" ]]; then
    return 0
  fi
  # Ignore Podman's gvproxy/rootlessport network helper
  if echo "$info" | grep -qE "gvproxy|podman|rootlessport"; then
    return 0
  fi
  return 1
}

port_process_info() {
  local port="$1"
  local info

  info=$(lsof -i ":$port" -sTCP:LISTEN -P -n 2>/dev/null | tail -1)
  if [[ -z "$info" ]]; then
    echo "unknown"
    return
  fi

  local process pid
  process=$(echo "$info" | awk '{print $1}')
  pid=$(echo "$info" | awk '{print $2}')

  echo "PID: $pid  Process: $process"
}

# ── Find Next Available Port ───────────────────────────────────────────────

port_find_available() {
  local start_port="$1"
  local max_attempts="${2:-10}"
  local port=$start_port
  local attempts=0

  while (( attempts < max_attempts )); do
    if port_available "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
    attempts=$((attempts + 1))
  done

  return 1
}

# ── Read Ports From Service Manifests ─────────────────────────────────────

port_read_from_manifests() {
  # Reads service:port pairs from services/*.yaml using yq
  # Output: "service_name:host_port" per line
  local services_dir="${1:-./services}"

  if [[ ! -d "$services_dir" ]]; then
    return 1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    ui_error "yq is required to read service manifests but was not found in PATH"
    return 1
  fi

  for manifest in "$services_dir"/*.yaml; do
    [[ -f "$manifest" ]] || continue
    local svc_name
    svc_name=$(basename "$manifest" .yaml)

    # Extract host_port values using yq
    yq '.ports[].host_port // ""' "$manifest" 2>/dev/null | while read -r port; do
      [[ -n "$port" ]] && echo "${svc_name}:${port}"
    done
  done
}

# ── Interactive Port Conflict Resolution ───────────────────────────────────

port_resolve_conflict() {
  local service_name="$1"
  local default_port="$2"
  local state_key="$3"

  if port_available "$default_port"; then
    ui_success "$service_name: port $default_port is available"
    state_set_port "$state_key" "$default_port"
    return 0
  fi

  local process_info
  process_info=$(port_process_info "$default_port")

  echo
  ui_warning "Port $default_port is required by $service_name."
  echo
  echo -e "  Port $default_port is currently being used by:"
  echo
  echo -e "    $process_info"
  echo

  local choice
  choice=$(ui_choice "What would you like to do?" \
    "Stop the process" \
    "Use an alternative port" \
    "Cancel installation")

  case "$choice" in
    1)
      local pid
      pid=$(echo "$process_info" | grep -o 'PID: [0-9]*' | awk '{print $2}')
      if [[ -n "$pid" ]]; then
        local proc_owner
        proc_owner=$(ps -o user= -p "$pid" 2>/dev/null || echo "unknown")
        if [[ "$proc_owner" == "$USER" ]]; then
          if ui_confirm "Stop process $pid ($proc_owner)?"; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            if port_available "$default_port"; then
              ui_success "Process stopped. Port $default_port is now available."
              state_set_port "$state_key" "$default_port"
              return 0
            fi
          fi
        else
          ui_warning "This process requires administrator privileges."
          if ui_confirm "Stop process $pid (owned by $proc_owner)?" "N"; then
            sudo kill "$pid" 2>/dev/null || true
            sleep 1
            if port_available "$default_port"; then
              ui_success "Process stopped. Port $default_port is now available."
              state_set_port "$state_key" "$default_port"
              return 0
            fi
          fi
        fi
      fi
      ui_error "Could not free port $default_port"
      return 1
      ;;
    2)
      local alt_port
      alt_port=$(port_find_available $((default_port + 1)))
      if [[ -n "$alt_port" ]]; then
        if ui_confirm "Use port $alt_port instead of $default_port?"; then
          ui_success "$service_name: using port $alt_port"
          state_set_port "$state_key" "$alt_port"
          return 0
        fi
      fi
      ui_error "No alternative port found"
      return 1
      ;;
    3)
      ui_info "Installation cancelled by user."
      exit 0
      ;;
    *)
      ui_error "Invalid choice"
      return 1
      ;;
  esac
}

# ── Check All Required Ports ───────────────────────────────────────────────

port_check_all() {
  local all_ok=true
  local project_root="${PROJECT_ROOT:-.}"

  ui_section "Port Validation"

  # Read ports from service manifests — single source of truth
  local port_entries
  port_entries=$(port_read_from_manifests "$project_root/services")

  if [[ -z "$port_entries" ]]; then
    ui_error "No service manifests found in $project_root/services"
    echo
    echo -e "  ${DIM}Make sure you are running this from the repository root.${RESET}"
    echo -e "  ${DIM}The services/ directory should contain *.yaml files.${RESET}"
    echo
    return 1
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local service="${entry%%:*}"
    local port="${entry##*:}"

    if ! port_resolve_conflict "$service" "$port" "$service"; then
      all_ok=false
    fi
  done <<< "$port_entries"

  if $all_ok; then
    ui_success "All required ports are available"
    return 0
  else
    ui_error "Some ports could not be allocated"
    return 1
  fi
}