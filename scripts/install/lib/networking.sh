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
  local pid_file="$state_dir/dnsmasq.pid"

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

start_mac_dhcp_server() {
  local iface="$1"
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local state_dir="$root_dir/state"

  setup_dnsmasq_config "$iface"

  local conf_file="$state_dir/dnsmasq.conf"
  local pid_file="$state_dir/dnsmasq.pid"

  # Stop any existing instance
  stop_mac_dhcp_server

  # Ensure dnsmasq binary exists (installed via brew)
  if ! command -v dnsmasq >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/sbin/dnsmasq ]]; then
      export PATH="/opt/homebrew/sbin:$PATH"
    elif [[ -x /usr/local/sbin/dnsmasq ]]; then
      export PATH="/usr/local/sbin:$PATH"
    fi
  fi

  if command -v dnsmasq >/dev/null 2>&1; then
    # Run dnsmasq with sudo in background
    sudo dnsmasq -C "$conf_file" -x "$pid_file" 2>/dev/null || true
    sleep 1
    return 0
  else
    return 1
  fi
}

stop_mac_dhcp_server() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local pid_file="$root_dir/state/dnsmasq.pid"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      sudo kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
}

reload_mac_dhcp_reservations() {
  local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  local pid_file="$root_dir/state/dnsmasq.pid"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      sudo kill -s SIGHUP "$pid" 2>/dev/null || true
    fi
  fi
}

# ── NAT Gateway ──────────────────────────────────────────────────────────────

enable_mac_nat_gateway() {
  local wan_if
  wan_if=$(get_wan_interface)
  [[ -z "$wan_if" ]] && return 1
  sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1 || true

  local anchor="/etc/pf.anchors/ai_platform_nat"
  printf 'nat on %s from %s to any -> (%s)\n' "$wan_if" "$INFERENCE_SUBNET" "$wan_if" \
    | sudo tee "$anchor" >/dev/null
  sudo pfctl -ef "$anchor" >/dev/null 2>&1 || true
}

disable_mac_nat_gateway() {
  sudo sysctl -w net.inet.ip.forwarding=0 >/dev/null 2>&1 || true
  local anchor="/etc/pf.anchors/ai_platform_nat"
  if [[ -f "$anchor" ]]; then
    sudo rm -f "$anchor"
    sudo pfctl -d >/dev/null 2>&1 || true
  fi
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
