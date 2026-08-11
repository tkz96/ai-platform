#!/usr/bin/env bash
# lib/networking.sh — Mac Mini inference-node networking helpers
# Handles: interface detection, static IP, sysctl forwarding, PF NAT,
#          SSH-based remote node configuration, and end-to-end health verification.

# ── Constants ────────────────────────────────────────────────────────────────

INFERENCE_SUBNET="10.42.0.0/24"
MAC_MINI_IP="10.42.0.1"
NODE_IP="10.42.0.2"
NODE_PORT="8080"
NETMASK="255.255.255.0"

# ── Interface Detection ──────────────────────────────────────────────────────

# Returns the macOS device name (e.g. "en0") for the built-in Ethernet port
get_ethernet_interface() {
  networksetup -listallhardwareports \
    | awk '/Hardware Port: Ethernet$/{getline; print $2}' \
    | head -n 1
}

# Returns the macOS service name (e.g. "Ethernet") for a given device
get_service_name() {
  local dev="$1"
  networksetup -listallhardwareports \
    | awk -v iface="$dev" '
        /Hardware Port:/ {port=substr($0,17)}
        /Device:/ {if ($2==iface) print port}
      '
}

# Returns the active WAN interface (Wi-Fi / Thunderbolt USB Ethernet)
get_wan_interface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2}' || true
}

# Returns true if the interface has a physical carrier (cable plugged in)
interface_has_link() {
  local iface="$1"
  ifconfig "$iface" 2>/dev/null | grep -q "status: active"
}

# ── Mac Mini Side ────────────────────────────────────────────────────────────

# Configure static 10.42.0.1/24 on the built-in Ethernet interface
configure_mac_static_ip() {
  local eth_if svc
  eth_if=$(get_ethernet_interface)
  [[ -z "$eth_if" ]] && return 1
  svc=$(get_service_name "$eth_if")
  [[ -z "$svc" ]] && return 1
  networksetup -setmanual "$svc" "$MAC_MINI_IP" "$NETMASK" 2>/dev/null || true
}

# Enable kernel IP forwarding
enable_ip_forwarding() {
  sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1 || true
}

# Set up macOS PF NAT rule — inference subnet → WAN
setup_pf_nat() {
  local wan_if
  wan_if=$(get_wan_interface)
  [[ -z "$wan_if" ]] && return 1
  local anchor="/etc/pf.anchors/ai_platform_nat"
  printf 'nat on %s from %s to any -> (%s)\n' "$wan_if" "$INFERENCE_SUBNET" "$wan_if" \
    | sudo tee "$anchor" >/dev/null
  sudo pfctl -ef "$anchor" >/dev/null 2>&1 || true
}

# ── Inference PC Discovery ───────────────────────────────────────────────────

# Look for any device reachable on en0 by checking ARP table
# Returns the IP that responded (could be 169.254.x.x if unconfigured)
discover_node_ip() {
  # First try the target static IP
  if ping -c 1 -W 1 "$NODE_IP" >/dev/null 2>&1; then
    echo "$NODE_IP"
    return 0
  fi
  # Fall back to ARP table on the inference Ethernet interface
  local eth_if
  eth_if=$(get_ethernet_interface)
  [[ -z "$eth_if" ]] && return 1
  arp -a -i "$eth_if" 2>/dev/null \
    | awk '!/incomplete/ && !/ff:ff:ff:ff:ff:ff/ {
        match($2, /\(([^)]+)\)/, a); if (a[1] != "") print a[1]
      }' \
    | grep -v "^$MAC_MINI_IP$" \
    | head -n 1
}

# ── SSH Remote Configuration ─────────────────────────────────────────────────

# Run a command on the inference PC via SSH; returns 0 on success
ssh_run() {
  local user="$1" host="$2" cmd="$3"
  ssh -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      -o BatchMode=yes \
      "${user}@${host}" "$cmd"
}

# Test SSH connectivity — returns 0 if accessible
ssh_reachable() {
  local user="$1" host="$2"
  ssh -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=accept-new \
      -o BatchMode=yes \
      "${user}@${host}" "echo ok" >/dev/null 2>&1
}

# Configure 10.42.0.2/24 + gateway on the inference PC over SSH
configure_node_network() {
  local user="$1" host="$2" eth_if="$3"
  ssh_run "$user" "$host" "
    set -e
    # Remove any existing address on this interface first
    sudo ip addr flush dev '$eth_if' 2>/dev/null || true
    sudo ip addr add $NODE_IP/24 dev '$eth_if'
    sudo ip link set '$eth_if' up
    sudo ip route replace default via $MAC_MINI_IP dev '$eth_if'
    # Persist via netplan if available
    if command -v netplan >/dev/null 2>&1; then
      sudo tee /etc/netplan/99-ai-platform.yaml >/dev/null <<NETPLAN
network:
  version: 2
  ethernets:
    $eth_if:
      dhcp4: no
      addresses: [$NODE_IP/24]
      routes:
        - to: default
          via: $MAC_MINI_IP
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
NETPLAN
      sudo netplan apply 2>/dev/null || true
    fi
  "
}

# Detect the wired Ethernet interface name on the inference PC
get_node_eth_interface() {
  local user="$1" host="$2"
  ssh_run "$user" "$host" \
    "ip -o link show | awk -F': ' '\$2 !~ /^lo|wl/ {print \$2; exit}'"
}

# Start llama-server on the inference PC in the background (nohup)
start_llama_server() {
  local user="$1" host="$2" binary="$3" model="$4"
  ssh_run "$user" "$host" \
    "nohup '$binary' --model '$model' --host 0.0.0.0 --port $NODE_PORT -c 8192 -ngl 99 \
     > /tmp/llama-server.log 2>&1 &
     sleep 2
     pgrep -f 'llama-server' >/dev/null && echo 'started' || echo 'failed'"
}

# ── Health Verification ──────────────────────────────────────────────────────

# Check if llama-server /health endpoint responds
node_api_healthy() {
  curl -sf --max-time 5 "http://${NODE_IP}:${NODE_PORT}/health" >/dev/null 2>&1
}

# Run a real completion call through LiteLLM using the LITELLM_MASTER_KEY
run_test_completion() {
  local master_key="$1"
  curl -sf --max-time 30 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $master_key" \
    -d '{"model":"qwen2.5-coder","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":64}' \
    "http://localhost:4000/v1/chat/completions"
}
