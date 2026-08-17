#!/usr/bin/env bash
# lib/networking.sh — Mac Mini inference-node networking helpers
# Handles: hardware-port interface enumeration, static IP configuration,
#          Podman VM network probe, and multi-stage connectivity verification.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

INFERENCE_SUBNET="10.42.0.0/24"
MAC_MINI_IP="10.42.0.1"
NODE_IP="10.42.0.2"
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

# ── Multi-Stage Network Verification ─────────────────────────────────────────

# Test 1: Mac Host TCP reachability
check_host_tcp_connection() {
  local host="${1:-$NODE_IP}"
  local port="${2:-$NODE_PORT}"
  nc -z -G 3 "$host" "$port" >/dev/null 2>&1
}

# Test 2: Mac Host HTTP health check
check_host_http_health() {
  local host="${1:-$NODE_IP}"
  local port="${2:-$NODE_PORT}"
  local endpoint="${3:-/health}"
  curl -sf --max-time 5 "http://${host}:${port}${endpoint}" >/dev/null 2>&1
}

# Test 3: Podman VM container HTTP health check
check_podman_vm_health() {
  local host="${1:-$NODE_IP}"
  local port="${2:-$NODE_PORT}"
  local endpoint="${3:-/health}"
  local probe_img
  probe_img=$(get_probe_image)
  podman run --rm "$probe_img" curl -sf --max-time 5 "http://${host}:${port}${endpoint}" >/dev/null 2>&1
}

# Test 4: LiteLLM container connectivity to backend
check_litellm_container_connectivity() {
  local host="${1:-$NODE_IP}"
  local port="${2:-$NODE_PORT}"
  local endpoint="${3:-/health}"
  podman exec litellm python3 -c "
import urllib.request
req = urllib.request.Request('http://${host}:${port}${endpoint}')
with urllib.request.urlopen(req, timeout=5) as resp:
    exit(0 if 200 <= resp.status < 400 else 1)
" >/dev/null 2>&1
}

# Test 5: LiteLLM chat completion integration test
run_test_completion() {
  local master_key="$1"
  curl -sf --max-time 30 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $master_key" \
    -d '{"model":"qwen2.5-coder","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":64}' \
    "http://localhost:4000/v1/chat/completions"
}

# Diagnostic helper: display peer MAC from ARP cache (optional diagnostic)
show_peer_mac_diagnostic() {
  local node_ip="${1:-$NODE_IP}"
  local mac
  mac=$(arp -n "$node_ip" 2>/dev/null | awk '{print $4}' | grep -v "incomplete" || true)
  if [[ -n "$mac" ]]; then
    echo "$mac"
  fi
}

# Optional NAT setup (strictly opt-in via --enable-nat-gateway)
enable_mac_nat_gateway() {
  local wan_if
  wan_if=$(get_wan_interface)
  [[ -z "$wan_if" ]] && return 1
  sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1 || true
  local anchor="/etc/pf.anchors/ai_platform_nat"
  printf 'nat on %s from %s to any -> (%s)\n' "$wan_if" "$INFERENCE_SUBNET" "$wan_if" \
    | sudo tee "$anchor" >/dev/null
  sudo pfctl -ef "$anchor" >/dev/null 2>&1 || true
}
