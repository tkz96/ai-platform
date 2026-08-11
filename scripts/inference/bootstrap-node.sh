#!/usr/bin/env bash
# AI Platform — Inference Node Bootstrap Script
# Configures Linux inference PC networking, static IP (10.42.0.2/24), gateway (10.42.0.1), and NAT connectivity.

set -euo pipefail

MAC_MINI_IP="10.42.0.1"
NODE_IP="10.42.0.2"
SUBNET_MASK="24"
DNS_SERVERS=("1.1.1.1" "8.8.8.8")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AI Platform — Inference Node Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# 1. Detect active Ethernet interface
echo "→ Auto-detecting Ethernet interface..."
ETH_IF=""
for iface in $(ip -o link show eth* enp* 2>/dev/null | awk -F': ' '{print $2}'); do
  if ip link show "$iface" | grep -q "state UP\|LOWER_UP"; then
    ETH_IF="$iface"
    break
  fi
done

if [[ -z "$ETH_IF" ]]; then
  # Fallback to first available ethernet interface name
  ETH_IF=$(ip -o link show | awk -F': ' '$2 !~ /^lo|wlan|wlp/ {print $2; exit}')
fi

if [[ -z "$ETH_IF" ]]; then
  echo "Error: No suitable Ethernet interface found." >&2
  exit 1
fi
echo "✓ Selected Ethernet interface: $ETH_IF"

# 2. Configure Netplan / static IP on Ubuntu/Debian
echo "→ Applying static IP ($NODE_IP/$SUBNET_MASK) and gateway ($MAC_MINI_IP)..."

if command -v netplan >/dev/null 2>&1; then
  NETPLAN_FILE="/etc/netplan/99-ai-platform-node.yaml"
  echo "Creating Netplan configuration at $NETPLAN_FILE..."
  sudo mkdir -p /etc/netplan
  cat <<EOF | sudo tee "$NETPLAN_FILE" >/dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    $ETH_IF:
      dhcp4: no
      addresses:
        - $NODE_IP/$SUBNET_MASK
      routes:
        - to: default
          via: $MAC_MINI_IP
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
EOF
  sudo netplan apply || true
else
  # Temporary ip route fallback if Netplan is not installed
  sudo ip addr add "$NODE_IP/$SUBNET_MASK" dev "$ETH_IF" 2>/dev/null || true
  sudo ip route add default via "$MAC_MINI_IP" dev "$ETH_IF" 2>/dev/null || true
fi

echo "✓ Network interface configured"

# 3. Test connectivity back to Mac Mini control plane
echo "→ Testing connectivity to Mac Mini ($MAC_MINI_IP)..."
if ping -c 2 -W 3 "$MAC_MINI_IP" >/dev/null 2>&1; then
  echo "✓ Successfully connected to Mac Mini at $MAC_MINI_IP"
else
  echo "Warning: Unable to ping Mac Mini at $MAC_MINI_IP. Check physical Ethernet cable connection." >&2
fi

# 4. Test external NAT internet forwarding
echo "→ Testing external NAT gateway forwarding (1.1.1.1)..."
if ping -c 2 -W 3 "1.1.1.1" >/dev/null 2>&1; then
  echo "✓ Internet access verified through Mac Mini NAT gateway"
else
  echo "Warning: External internet ping failed. Verify Mac Mini IP forwarding and PF NAT rules." >&2
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Inference Node Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
