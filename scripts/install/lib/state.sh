#!/usr/bin/env bash
# State tracking for bootstrap.sh
# Manages .install-state for idempotent installs and rollback.

set -euo pipefail

STATE_FILE="${PROJECT_ROOT:-.}/.install-state"

# ── State Initialization ────────────────────────────────────────────────────

state_init() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<'EOF'
{
  "version": "0.1.0",
  "installed_at": null,
  "phases": {},
  "podman_machine": {
    "name": "ai-platform",
    "cpus": 4,
    "memory_mb": 8192,
    "disk_gb": 60
  },
  "ports": {
    "caddy_http": 8080,
    "caddy_https": 8443,
    "litellm": 4000,
    "langfuse": 3000,
    "postgres": 5432,
    "clickhouse": 8123,
    "redis": 6379
  }
}
EOF
  fi
}

# ── Internal Primitives ─────────────────────────────────────────────────────

_state_get() {
  local jq_expr="$1"
  local default="$2"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "$default"
    return
  fi
  local res
  res=$(jq -r "$jq_expr // empty" "$STATE_FILE" 2>/dev/null)
  if [[ -z "$res" || "$res" == "null" ]]; then
    echo "$default"
  else
    echo "$res"
  fi
}

_state_set() {
  local jq_expr="$1"
  state_init
  local tmp
  tmp=$(mktemp)
  if jq "$jq_expr" "$STATE_FILE" > "$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

# ── State Queries ───────────────────────────────────────────────────────────

state_phase_status() {
  local phase="$1"
  _state_get ".phases[\"$phase\"].status" "not_started"
}

state_get_port() {
  local service="$1"
  local default="$2"
  _state_get ".ports[\"$service\"]" "$default"
}

state_get_podman_machine() {
  local key="$1"
  local default="$2"
  _state_get ".podman_machine[\"$key\"]" "$default"
}

# ── State Updates ───────────────────────────────────────────────────────────

state_set_phase() {
  local phase="$1"
  local status="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  state_init

  local installed_clause=""
  if [[ "$status" == "completed" ]]; then
    installed_clause=' | if .installed_at == null then .installed_at = "'"$timestamp"'" else . end'
  fi

  _state_set '.phases["'"$phase"'"] = {"status": "'"$status"'", "timestamp": "'"$timestamp"'"}'"$installed_clause"
}

state_set_port() {
  local service="$1"
  local port="$2"

  state_init
  _state_set '.ports["'"$service"'"] = ('"$port"' | tonumber)'
}

# ── Phase Runner ────────────────────────────────────────────────────────────

state_run_phase() {
  local phase_name="$1"
  local phase_script="$2"
  local status

  status=$(state_phase_status "$phase_name")

  if [[ "$status" == "completed" ]]; then
    ui_success "$phase_name (already completed)"
    return 0
  fi

  if [[ "$status" == "failed" || "$status" == "aborted" ]]; then
    ui_warning "$phase_name previously $status"
    if ! ui_confirm "Retry $phase_name?"; then
      ui_error "Skipping $phase_name"
      return 1
    fi
  fi

  state_set_phase "$phase_name" "in_progress"

  if bash "$phase_script"; then
    state_set_phase "$phase_name" "completed"
    return 0
  else
    local rc=$?
    if [[ $rc -eq 130 ]]; then
      state_set_phase "$phase_name" "aborted"
    else
      state_set_phase "$phase_name" "failed"
    fi
    return 1
  fi
}


# ── Rollback ────────────────────────────────────────────────────────────────

state_rollback() {
  local failed_phase="$1"

  ui_section "Rollback"
  ui_warning "Phase '$failed_phase' failed."
  ui_info "Restoring from backup if available..."

  local backup_dir="${PROJECT_ROOT:-.}/backups"
  local latest_backup

  if [[ -d "$backup_dir" ]]; then
    latest_backup=$(ls -t "$backup_dir"/backup_*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
      ui_info "Found backup: $latest_backup"
      if ui_confirm "Restore from this backup?"; then
        tar -xzf "$latest_backup" -C "${PROJECT_ROOT:-.}"
        ui_success "Backup restored"
        return 0
      fi
    fi
  fi

  ui_warning "No backup available for rollback."
  ui_info "You can manually fix the issue and re-run: ./bootstrap.sh"
  return 1
}

# ── State Reset ─────────────────────────────────────────────────────────────

state_reset() {
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    ui_success "Install state cleared"
  fi
}

# ── State Display ───────────────────────────────────────────────────────────

state_show() {
  if [[ ! -f "$STATE_FILE" ]]; then
    ui_info "No install state found. Run ./bootstrap.sh to install."
    return
  fi

  ui_section "Install State"
  jq -r '
    "  Version:      \(.version // "unknown")",
    "  Installed at: \(.installed_at // "never")\n",
    "  Phases:",
    (.phases // {} | to_entries[] | "    \(if .value.status == "completed" then "✓" elif .value.status == "failed" then "✗" else "→" end) \(.key): \(.value.status)"),
    "\n  Ports:",
    (.ports // {} | to_entries[] | "    \(.key): \(.value)")
  ' "$STATE_FILE"
}