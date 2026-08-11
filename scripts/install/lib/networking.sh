#!/usr/bin/env bash
# Library functions for macOS NAT and IP forwarding for inference subnet (10.42.0.0/24)

set -euo pipefail

INFERENCE_SUBNET="10.42.0.0/24"
MAC_MINI_IP="10.42.0.1"
NETMASK="255.255.255.0"

# Detect dedicated built-in Ethernet interface name on macOS
get_ethernet_interface() {
  networksetup -listallhardwareports | awk '/Hardware Port: Ethernet/{getline; print $2}' | head -n 1
}

# Detect active WAN interface (Wi-Fi or Thunderbolt Ethernet)
get_wan_interface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2}' || echo ""
}

# Configure static IP 10.42.0.1 on direct Ethernet link
configure_static_ip() {
  local eth_if
  eth_if=$(get_ethernet_interface)
  if [[ -z "$eth_if" ]]; then
    echo "Warning: Built-in Ethernet interface not found." >&2
    return 1
  fi

  local service_name
  service_name=$(networksetup -listallhardwareports | awk -v iface="$eth_if" '
    /Hardware Port:/ {port=$0; sub(/Hardware Port: /, "", port)}
    /Device:/ {if ($2 == iface) print port}
  ')

  if [[ -n "$service_name" ]]; then
    networksetup -setmanual "$service_name" "$MAC_MINI_IP" "$NETMASK" 2>/dev/null || true
  fi
}

# Enable sysctl IP forwarding
enable_ip_forwarding() {
  sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1 || true
}

# Setup macOS PF NAT rules
setup_pf_nat() {
  local wan_if
  wan_if=$(get_wan_interface)
  if [[ -z "$wan_if" ]]; then
    echo "Warning: Active WAN interface not detected." >&2
    return 1
  fi

  local pf_anchor="/etc/pf.anchors/ai_platform_nat"
  local nat_rule="nat on $wan_if from $INFERENCE_SUBNET to any -> ($wan_if)"

  echo "$nat_rule" | sudo tee "$pf_anchor" >/dev/null
  sudo pfctl -ef "$pf_anchor" >/dev/null 2>&1 || true
}
