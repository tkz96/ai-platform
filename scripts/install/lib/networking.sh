#!/usr/bin/env bash
# lib/networking.sh — Mac Mini inference-node networking helpers
# Handles: hardware-port interface enumeration, static IP configuration,
#          dnsmasq DHCP server lifecycle, PF NAT, and multi-node connectivity verification.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

INFERENCE_SUBNET="10.42.0.0/24"
MAC_MINI_IP="10.42.0.1"
NODE_PORT="8080"
NETMASK="255.255.255.0"

# Canonical probe image pinned by digest
DEFAULT_PROBE_IMAGE="docker.io/curlimages/curl@sha256:c3b8bee303c6c6beed656cfc921218c529d65aa61114eb9e27c62047a1271b9b"

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v ui_error >/dev/null 2>&1; then
  [[ -f "$SCRIPT_LIB_DIR/ui.sh" ]] && source "$SCRIPT_LIB_DIR/ui.sh"
fi
if [[ -f "$SCRIPT_LIB_DIR/diagnostics.sh" ]]; then
  source "$SCRIPT_LIB_DIR/diagnostics.sh"
fi

get_probe_image() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  if [[ -f "$root_dir/platform.yaml" ]] && command -v yq >/dev/null 2>&1; then
    local img
    img=$(yq '.network.probe_image // ""' "$root_dir/platform.yaml" 2>/dev/null || echo "")
    if [[ -n "$img" ]]; then
      echo "$img"
      return 0
    fi
  fi
  echo "$DEFAULT_PROBE_IMAGE"
}

# ── Hardware Port Interface Enumeration ──────────────────────────────────────

# Returns lines of "ServiceName|DeviceName|MACAddress" for physical Ethernet ports
list_physical_ethernet_candidates() {
  networksetup -listallhardwareports 2>/dev/null | awk '
    /Hardware Port:/ { port=substr($0, 16) }
    /Device:/ { dev=$2 }
    /Ethernet Address:/ {
      mac=$2
      if (port ~ /(Ethernet|LAN|Thunderbolt)/ && port !~ /(Wi-Fi|AirPort|Bluetooth)/) {
        print port "|" dev "|" mac
      }
    }
  '
}

# Returns the active default-route interface (WAN)
get_wan_interface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true
}

# Returns true if interface has physical carrier
interface_has_link() {
  local iface="$1"
  ifconfig "$iface" 2>/dev/null | grep -q "status: active"
}

# Returns current IPv4 on interface if any
interface_get_ip() {
  local iface="$1"
  ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | grep -v "^127\." | head -n 1 || true
}

# Returns media/speed string
interface_get_media() {
  local iface="$1"
  ifconfig "$iface" 2>/dev/null | awk -F': ' '/media:/{print $2}' | head -n 1 || echo "unknown"
}

# Returns service name for a given device
get_service_name_for_device() {
  local target_dev="$1"
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="$target_dev" '
    /Hardware Port:/ { port=substr($0, 16) }
    /Device:/ { if ($2 == dev) print port }
  ' | head -n 1
}

# Safely selects the private Ethernet interface, preventing WAN hijacking in non-interactive mode
select_private_ethernet_interface() {
  local wan_if
  wan_if=$(get_wan_interface)
  local candidates_raw
  candidates_raw=$(list_physical_ethernet_candidates)

  if [[ -z "$candidates_raw" ]]; then
    ui_error "No physical Ethernet/Thunderbolt interfaces detected on this Mac."
    return 1
  fi

  local lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<< "$candidates_raw"

  local count="${#lines[@]}"
  local devs=()
  local svcs=()
  local non_wan_devs=()
  local non_wan_svcs=()

  for line in "${lines[@]}"; do
    local svc dev mac
    svc=$(echo "$line" | cut -d'|' -f1)
    dev=$(echo "$line" | cut -d'|' -f2)
    mac=$(echo "$line" | cut -d'|' -f3)

    devs+=("$dev")
    svcs+=("$svc")

    if [[ "$dev" != "$wan_if" ]]; then
      non_wan_devs+=("$dev")
      non_wan_svcs+=("$svc")
    fi
  done

  # Non-interactive mode
  if is_noninteractive; then
    # Prefer non-WAN device with active carrier link
    for i in "${!non_wan_devs[@]}"; do
      if interface_has_link "${non_wan_devs[$i]}"; then
        echo "${non_wan_devs[$i]}|${non_wan_svcs[$i]}"
        return 0
      fi
    done
    # Fallback to first non-WAN candidate
    if (( ${#non_wan_devs[@]} > 0 )); then
      echo "${non_wan_devs[0]}|${non_wan_svcs[0]}"
      return 0
    fi
    ui_error "Only WAN interface ($wan_if) detected. Cannot safely assign private IP in non-interactive mode."
    return 1
  fi

  # Interactive mode: Single candidate
  if (( count == 1 )); then
    echo "${devs[0]}|${svcs[0]}"
    return 0
  fi

  # Interactive mode: Multiple candidates prompt
  local idx=1
  for line in "${lines[@]}"; do
    local svc dev mac is_default="NO"
    svc=$(echo "$line" | cut -d'|' -f1)
    dev=$(echo "$line" | cut -d'|' -f2)
    mac=$(echo "$line" | cut -d'|' -f3)
    [[ "$dev" == "$wan_if" ]] && is_default="YES (Active Internet/WAN)"
    echo -e "  [${idx}] ${svc} (${dev}) - MAC: ${mac} - Default Route: ${is_default}" >&2
    idx=$((idx + 1))
  done

  local sel_num
  sel_num=$(ui_prompt_text "Select Ethernet interface for private inference link (1-$count)" "1")
  local sel_idx=$(( sel_num - 1 ))
  if (( sel_idx < 0 || sel_idx >= count )); then
    sel_idx=0
  fi

  local chosen_dev="${devs[$sel_idx]}"
  local chosen_svc="${svcs[$sel_idx]}"

  if [[ "$chosen_dev" == "$wan_if" ]]; then
    ui_warning "CAUTION: Interface $chosen_dev carries your primary Internet route!"
    if ! ui_confirm "Are you sure you want to repurpose $chosen_dev?" "N"; then
      return 1
    fi
  fi

  echo "${chosen_dev}|${chosen_svc}"
  return 0
}

# ── Mac Mini Interface Configuration ─────────────────────────────────────────

configure_mac_inference_interface() {
  local dev="$1"
  local svc
  svc=$(get_service_name_for_device "$dev")
  if [[ -z "$svc" ]]; then
    return 1
  fi
  networksetup -setmanual "$svc" "$MAC_MINI_IP" "$NETMASK" 2>/dev/null || true
}

verify_mac_inference_interface() {
  local dev="$1"
  ifconfig "$dev" 2>/dev/null | grep -q "inet $MAC_MINI_IP "
}

# ── DHCP Server (dnsmasq) Management ─────────────────────────────────────────

setup_dnsmasq_config() {
  local iface="$1"
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local state_dir="$root_dir/state"
  mkdir -p "$state_dir"

  local conf_file="$state_dir/dnsmasq.conf"
  local hosts_file="$state_dir/dnsmasq.hosts"
  local lease_file="$state_dir/dnsmasq.leases"

  touch "$hosts_file"
  touch "$lease_file"

  cat > "$conf_file" <<EOF
# AI Platform dnsmasq Configuration
# Dedicated private interface only
interface=$iface
bind-interfaces
listen-address=$MAC_MINI_IP

# Temporary DHCP pool for fresh enrolling nodes
dhcp-range=10.42.0.100,10.42.0.200,$NETMASK,1h

# DHCP Options: Gateway & DNS pointing to Mac
dhcp-option=option:router,$MAC_MINI_IP
dhcp-option=option:dns-server,$MAC_MINI_IP

# Static reservations file
dhcp-hostsfile=$hosts_file
dhcp-leasefile=$lease_file

# Upstream DNS forwarding
server=1.1.1.1
server=8.8.8.8
domain=ai.xynotech.internal
local=/ai.xynotech.internal/
EOF
}

stop_mac_dhcp_server() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local conf_file="$root_dir/state/dnsmasq.conf"
  local pid_file="/tmp/ai-platform-dnsmasq.pid"

  # 1. Try PID file based termination with exact process identity verification
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && sudo kill -0 "$pid" 2>/dev/null; then
      local cmd
      cmd=$(ps -p "$pid" -o command= 2>/dev/null || echo "")
      if [[ "$cmd" == *"$conf_file"* ]] || [[ "$cmd" == *"dnsmasq"* ]]; then
        sudo kill "$pid" 2>/dev/null || true
      fi
    fi
    sudo rm -f "$pid_file" 2>/dev/null || rm -f "$pid_file" 2>/dev/null || true
  fi

  # 2. Fallback: Check if another running dnsmasq process matches our exact config file
  local matching_pids
  matching_pids=$(ps aux 2>/dev/null | grep "[d]nsmasq.*${conf_file}" | awk '{print $2}' || true)
  if [[ -n "$matching_pids" ]]; then
    while IFS= read -r mpid; do
      [[ -z "$mpid" ]] && continue
      sudo kill "$mpid" 2>/dev/null || true
    done <<< "$matching_pids"
  fi
}

start_mac_dhcp_server() {
  local iface="$1"
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local state_dir="$root_dir/state"

  setup_dnsmasq_config "$iface"

  local conf_file="$state_dir/dnsmasq.conf"
  local err_file="$state_dir/dnsmasq.err"
  local pid_file="/tmp/ai-platform-dnsmasq.pid"

  # Stop any existing instance using exact matching
  stop_mac_dhcp_server

  # Ensure dnsmasq binary exists (installed via brew)
  if ! command -v dnsmasq >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/sbin/dnsmasq ]]; then
      export PATH="/opt/homebrew/sbin:$PATH"
    elif [[ -x /usr/local/sbin/dnsmasq ]]; then
      export PATH="/usr/local/sbin:$PATH"
    fi
  fi

  if ! command -v dnsmasq >/dev/null 2>&1; then
    ui_error "dnsmasq binary not found in PATH or Homebrew sbin directories."
    return 1
  fi

  # Validate dnsmasq configuration syntax
  local test_err
  if ! test_err=$(dnsmasq --test -C "$conf_file" 2>&1); then
    ui_error "dnsmasq syntax check failed: $test_err"
    return 1
  fi

  # Run dnsmasq with sudo, capturing stderr to err_file
  rm -f "$err_file"
  if ! sudo dnsmasq -C "$conf_file" -x "$pid_file" 2>"$err_file"; then
    local captured_err
    captured_err=$(cat "$err_file" 2>/dev/null || echo "Unknown startup failure")
    local port67_owner
    port67_owner=$(sudo lsof -nP -iUDP:67 2>/dev/null | tail -n +2 || echo "none")
    if command -v render_diagnostic_box >/dev/null 2>&1; then
      render_diagnostic_box \
        "dnsmasq DHCP Server Startup" \
        "sudo dnsmasq -C $conf_file -x $pid_file" \
        "1" \
        "$captured_err" \
        "Interface: $iface\nIP: $MAC_MINI_IP\nUDP/67 Owner:\n$port67_owner" \
        "Check if another DHCP service is running or if port 67 is bound."
    fi
    return 1
  fi

  # Verify process liveness and PID file creation
  local retries=6
  while (( retries > 0 )); do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && sudo kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 0.5
    retries=$(( retries - 1 ))
  done

  local captured_err
  captured_err=$(cat "$err_file" 2>/dev/null || echo "PID file $pid_file was not created or process died")
  local port67_owner
  port67_owner=$(sudo lsof -nP -iUDP:67 2>/dev/null | tail -n +2 || echo "none")
  if command -v render_diagnostic_box >/dev/null 2>&1; then
    render_diagnostic_box \
      "dnsmasq Liveness Check" \
      "sudo kill -0 (PID from $pid_file)" \
      "1" \
      "$captured_err" \
      "PID File: $pid_file\nUDP/67 Owner:\n$port67_owner" \
      "Verify dnsmasq permissions and interface link state."
  fi
  return 1
}

restart_mac_dhcp_server() {
  local iface="$1"
  stop_mac_dhcp_server
  start_mac_dhcp_server "$iface"
}

diagnose_mac_dhcp_server() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local conf_file="$root_dir/state/dnsmasq.conf"
  local pid_file="/tmp/ai-platform-dnsmasq.pid"

  echo "=== dnsmasq Diagnostic Check ==="
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && sudo kill -0 "$pid" 2>/dev/null; then
      echo "[OK] dnsmasq PID $pid is running."
      ps -p "$pid" -o pid,user,command=
    else
      echo "[WARN] PID file exists ($pid_file) but process $pid is not active."
    fi
  else
    echo "[WARN] No PID file at $pid_file."
  fi

  local port67_owner
  port67_owner=$(sudo lsof -nP -iUDP:67 2>/dev/null || echo "none")
  echo "UDP/67 Owner:"
  echo "$port67_owner"
}


reload_mac_dhcp_reservations() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local conf_file="$root_dir/state/dnsmasq.conf"
  local pid_file="/tmp/ai-platform-dnsmasq.pid"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && sudo kill -0 "$pid" 2>/dev/null; then
      local cmd
      cmd=$(ps -p "$pid" -o command= 2>/dev/null || echo "")
      if [[ "$cmd" == *"$conf_file"* ]] || [[ "$cmd" == *"dnsmasq"* ]]; then
        sudo kill -s SIGHUP "$pid" 2>/dev/null || true
      fi
    fi
  fi
}

# ── NAT Gateway ──────────────────────────────────────────────────────────────

enable_mac_nat_gateway() {
  local wan_if
  wan_if=$(get_wan_interface)
  [[ -z "$wan_if" ]] && return 1

  # Enable IP forwarding
  if ! sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1; then
    return 1
  fi

  # PF Anchor Safety: write rule to dedicated anchor without replacing global PF ruleset
  local anchor_dir="/etc/pf.anchors"
  local anchor_file="$anchor_dir/ai_platform_nat"
  sudo mkdir -p "$anchor_dir" 2>/dev/null || true

  printf 'nat on %s from %s to any -> (%s)\n' "$wan_if" "$INFERENCE_SUBNET" "$wan_if" \
    | sudo tee "$anchor_file" >/dev/null

  # Enable PF subsystem if not already active
  sudo pfctl -e >/dev/null 2>&1 || true

  # Load only the platform NAT rule into the dedicated anchor
  if ! sudo pfctl -a ai_platform_nat -f "$anchor_file" >/dev/null 2>&1; then
    return 1
  fi

  # Verify anchor is active
  if ! sudo pfctl -a ai_platform_nat -sn 2>/dev/null | grep -q "nat on $wan_if"; then
    return 1
  fi

  return 0
}

disable_mac_nat_gateway() {
  sudo sysctl -w net.inet.ip.forwarding=0 >/dev/null 2>&1 || true
  local anchor_file="/etc/pf.anchors/ai_platform_nat"
  if [[ -f "$anchor_file" ]]; then
    # Flush only the dedicated AI platform anchor
    sudo pfctl -a ai_platform_nat -F all >/dev/null 2>&1 || true
    sudo rm -f "$anchor_file"
  fi
}

smoke_test_mac_network_services() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local pid_file="/tmp/ai-platform-dnsmasq.pid"

  # 1. Verify dnsmasq process liveness
  if [[ ! -f "$pid_file" ]]; then
    return 1
  fi
  local pid
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  if [[ -z "$pid" ]] || ! sudo kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  # 2. Verify enrollment server endpoint readiness
  local retries=10
  while (( retries > 0 )); do
    if curl -sf --max-time 2 "http://$MAC_MINI_IP:8765/api/enroll/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    retries=$(( retries - 1 ))
  done

  return 1
}

# ── Multi-Stage Network Verification ─────────────────────────────────────────

check_host_tcp_connection() {
  local host="${1:-10.42.0.2}"
  local port="${2:-8080}"
  nc -z -G 3 "$host" "$port" >/dev/null 2>&1
}

check_host_http_health() {
  local host="${1:-10.42.0.2}"
  local port="${2:-8080}"
  local endpoint="${3:-/health}"
  curl -sf --max-time 5 "http://${host}:${port}${endpoint}" >/dev/null 2>&1
}

check_podman_vm_health() {
  local host="${1:-10.42.0.2}"
  local port="${2:-8080}"
  local endpoint="${3:-/health}"
  local probe_img
  probe_img=$(get_probe_image)
  podman run --rm "$probe_img" curl -sf --max-time 5 "http://${host}:${port}${endpoint}" >/dev/null 2>&1
}

check_litellm_container_connectivity() {
  local host="${1:-10.42.0.2}"
  local port="${2:-8080}"
  local endpoint="${3:-/health}"
  podman exec litellm python3 -c "
import urllib.request
req = urllib.request.Request('http://${host}:${port}${endpoint}')
with urllib.request.urlopen(req, timeout=5) as resp:
    exit(0 if 200 <= resp.status < 400 else 1)
" >/dev/null 2>&1
}

run_test_completion() {
  local master_key="$1"
  local model="${2:-qwen2.5-coder}"
  curl -sf --max-time 30 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $master_key" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}],\"max_tokens\":64}" \
    "http://localhost:4000/v1/chat/completions"
}

show_peer_mac_diagnostic() {
  local node_ip="${1:-10.42.0.2}"
  local mac
  mac=$(arp -n "$node_ip" 2>/dev/null | awk '{print $4}' | grep -v "incomplete" || true)
  if [[ -n "$mac" ]]; then
    echo "$mac"
  fi
}
