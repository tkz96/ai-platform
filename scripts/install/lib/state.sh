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

# ── State Queries ───────────────────────────────────────────────────────────

state_phase_status() {
  local phase="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "not_started"
    return
  fi
  local status
  status=$(python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    data = json.load(f)
phase = data.get('phases', {}).get('$phase', {})
print(phase.get('status', 'not_started'))
" 2>/dev/null || echo "not_started")
  echo "$status"
}

state_get_port() {
  local service="$1"
  local default="$2"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "$default"
    return
  fi
  python3 -c "
import json
with open('$STATE_FILE') as f:
    data = json.load(f)
print(data.get('ports', {}).get('$service', $default))
" 2>/dev/null || echo "$default"
}

state_get_podman_machine() {
  local key="$1"
  local default="$2"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "$default"
    return
  fi
  python3 -c "
import json
with open('$STATE_FILE') as f:
    data = json.load(f)
print(data.get('podman_machine', {}).get('$key', '$default'))
" 2>/dev/null || echo "$default"
}

# ── State Updates ───────────────────────────────────────────────────────────

state_set_phase() {
  local phase="$1"
  local status="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  state_init

  python3 -c "
import json
with open('$STATE_FILE') as f:
    data = json.load(f)
if 'phases' not in data:
    data['phases'] = {}
data['phases']['$phase'] = {
    'status': '$status',
    'timestamp': '$timestamp'
}
if '$status' == 'completed' and data.get('installed_at') is None:
    data['installed_at'] = '$timestamp'
with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
}

state_set_port() {
  local service="$1"
  local port="$2"

  state_init

  python3 -c "
import json
with open('$STATE_FILE') as f:
    data = json.load(f)
if 'ports' not in data:
    data['ports'] = {}
data['ports']['$service'] = $port
with open('$STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
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

  if [[ "$status" == "failed" ]]; then
    ui_warning "$phase_name previously failed"
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
    state_set_phase "$phase_name" "failed"
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
  python3 -c "
import json
with open('$STATE_FILE') as f:
    data = json.load(f)

print(f\"  Version:      {data.get('version', 'unknown')}\")
print(f\"  Installed at: {data.get('installed_at', 'never')}\")
print()
print('  Phases:')
for phase, info in data.get('phases', {}).items():
    status = info.get('status', 'unknown')
    symbol = '✓' if status == 'completed' else '✗' if status == 'failed' else '→'
    print(f'    {symbol} {phase}: {status}')
print()
print('  Ports:')
for service, port in data.get('ports', {}).items():
    print(f'    {service}: {port}')
"
}