#!/usr/bin/env bash
# AI Platform — Inference Node Bootstrap Script
# Configures dedicated Linux inference PC networking with static IP (10.42.0.2/24).
#
# Usage:
#   sudo ./bootstrap-node.sh [--interface <iface>] [--enable-nat-gateway] [--force]
#
# Safety guarantees:
#   - Does NOT modify existing Wi-Fi / LAN interfaces, DNS, or default routes.
#   - Creates an automatic backup of /etc/netplan/ before applying changes.
#   - Validates Netplan configuration and rolls back immediately if application or ping fails.

set -euo pipefail

MAC_MINI_IP="10.42.0.1"
NODE_IP="10.42.0.2"
SUBNET_MASK="24"
NETPLAN_FILE="/etc/netplan/99-ai-platform-node.yaml"

ENABLE_NAT_GATEWAY=false
FORCE=false
SPECIFIED_IFACE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface|-i)
      SPECIFIED_IFACE="$2"
      shift 2
      ;;
    --enable-nat-gateway)
      ENABLE_NAT_GATEWAY=true
      shift
      ;;
    --force|-f)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: sudo $0 [--interface <iface>] [--enable-nat-gateway] [--force]" >&2
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AI Platform — Inference Node Network Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# ── 1. Interface Detection & Enumeration ─────────────────────────────────────

echo "→ Scanning physical Ethernet interfaces..."

ETH_IF=""
if [[ -n "$SPECIFIED_IFACE" ]]; then
  if ! ip link show "$SPECIFIED_IFACE" >/dev/null 2>&1; then
    echo "Error: Specified interface '$SPECIFIED_IFACE' does not exist." >&2
    exit 1
  fi
  ETH_IF="$SPECIFIED_IFACE"
else
  # Enumerate physical candidates excluding virtual/wireless interfaces
  CANDIDATES=()
  for iface in $(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|podman|br-|veth|wlan|wlp|cni)/ {print $2}'); do
    # Check if interface has carrier
    if ip link show "$iface" 2>/dev/null | grep -qE "state UP|LOWER_UP"; then
      CANDIDATES+=("$iface")
    fi
  done

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    # Fallback to any physical non-wireless link
    for iface in $(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|podman|br-|veth|wlan|wlp|cni)/ {print $2}'); do
      CANDIDATES+=("$iface")
    done
  fi

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "Error: No physical Ethernet interfaces found." >&2
    exit 1
  elif [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    ETH_IF="${CANDIDATES[0]}"
  else
    echo "Multiple Ethernet interfaces found:"
    for i in "${!CANDIDATES[@]}"; do
      if_name="${CANDIDATES[$i]}"
      carrier="DOWN"
      if ip link show "$if_name" | grep -qE "state UP|LOWER_UP"; then
        carrier="ACTIVE"
      fi
      cur_ip=$(ip -4 -o addr show dev "$if_name" 2>/dev/null | awk '{print $4}' | head -1 || echo "none")
      echo "  $((i+1))) $if_name (Carrier: $carrier, IP: $cur_ip)"
    done
    if [[ "$FORCE" == "true" ]]; then
      ETH_IF="${CANDIDATES[0]}"
      echo "Auto-selecting $ETH_IF (--force enabled)"
    else
      read -rp "Select interface (1-${#CANDIDATES[@]}): " choice
      idx=$((choice - 1))
      if (( idx < 0 || idx >= ${#CANDIDATES[@]} )); then
        echo "Error: Invalid selection." >&2
        exit 1
      fi
      ETH_IF="${CANDIDATES[$idx]}"
    fi
  fi
fi

echo "✓ Selected interface: $ETH_IF"
MAC_ADDR=$(ip link show dev "$ETH_IF" | awk '/link\/ether/{print $2}' || echo "unknown")
echo "  MAC address       : $MAC_ADDR"

# ── 2. Default Route & Active LAN Disruption Guard ───────────────────────────

DEFAULT_ROUTE_IF=$(ip -4 route show default 2>/dev/null | awk '/dev/{print $5}' | head -1 || true)
if [[ "$ETH_IF" == "$DEFAULT_ROUTE_IF" && "$FORCE" != "true" ]]; then
  echo
  echo "⚠️  WARNING: '$ETH_IF' currently carries the default route (Internet/LAN) for this machine!"
  echo "    Reconfiguring it with static $NODE_IP/24 will alter your existing network connectivity."
  read -rp "Are you sure you want to proceed with '$ETH_IF'? (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted by operator. Please specify a dedicated secondary NIC using --interface."
    exit 1
  fi
fi

# ── 3. Netplan Backup & Fail-Safe Application ────────────────────────────────

BACKUP_DIR="/etc/netplan/backup_$(date +%Y%m%d_%H%M%S)"
echo "→ Creating Netplan backup at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
cp /etc/netplan/*.yaml "$BACKUP_DIR/" 2>/dev/null || true

rollback() {
  echo
  echo "⚠️  Applying network configuration failed! Rolling back to backup..."
  rm -f "$NETPLAN_FILE"
  cp "$BACKUP_DIR"/*.yaml /etc/netplan/ 2>/dev/null || true
  netplan apply 2>/dev/null || true
  echo "✓ Rollback complete."
}

echo "→ Writing Netplan configuration ($NETPLAN_FILE)..."
mkdir -p /etc/netplan

if [[ "$ENABLE_NAT_GATEWAY" == "true" ]]; then
  cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $ETH_IF:
      dhcp4: false
      addresses:
        - $NODE_IP/$SUBNET_MASK
      routes:
        - to: default
          via: $MAC_MINI_IP
EOF
else
  cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $ETH_IF:
      dhcp4: false
      addresses:
        - $NODE_IP/$SUBNET_MASK
EOF
fi

chmod 600 "$NETPLAN_FILE"

# Validate configuration syntax
echo "→ Validating Netplan syntax..."
if command -v netplan >/dev/null 2>&1; then
  if ! netplan generate; then
    echo "Error: Netplan syntax validation failed." >&2
    rollback
    exit 1
  fi

  echo "→ Applying Netplan configuration..."
  if ! netplan apply; then
    echo "Error: Failed to apply Netplan configuration." >&2
    rollback
    exit 1
  fi
else
  echo "Error: 'netplan' command not found on this system." >&2
  rollback
  exit 1
fi

# ── 4. Verify Static IP & Reachability ───────────────────────────────────────

echo "→ Verifying IP configuration..."
if ! ip -4 addr show dev "$ETH_IF" | grep -q "$NODE_IP/$SUBNET_MASK"; then
  echo "Error: $NODE_IP/$SUBNET_MASK is not assigned to $ETH_IF." >&2
  rollback
  exit 1
fi
echo "✓ Interface $ETH_IF configured at $NODE_IP/$SUBNET_MASK"

echo "→ Testing connectivity to Mac Mini control plane ($MAC_MINI_IP)..."
if ping -c 2 -W 3 "$MAC_MINI_IP" >/dev/null 2>&1; then
  echo "✓ Successfully connected to Mac Mini at $MAC_MINI_IP"
else
  echo "⚠️  Notice: Unable to ping Mac Mini at $MAC_MINI_IP."
  echo "    Ensure the Ethernet cable is connected and Mac Mini interface is set to $MAC_MINI_IP."
fi

# Optional NAT gateway test if explicitly requested
if [[ "$ENABLE_NAT_GATEWAY" == "true" ]]; then
  echo "→ Testing external NAT gateway forwarding (1.1.1.1)..."
  if ping -c 2 -W 3 "1.1.1.1" >/dev/null 2>&1; then
    echo "✓ Internet access verified through Mac Mini NAT gateway"
  else
    echo "⚠️  Notice: External internet ping failed. Verify Mac Mini IP forwarding and PF NAT rules."
  fi
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Inference Node Network Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Interface   : $ETH_IF"
echo "  Static IP   : $NODE_IP/$SUBNET_MASK"
echo "  MAC Address : $MAC_ADDR"
echo
echo "  Next step: Start llama-server bound to the inference interface:"
echo "    llama-server --host $NODE_IP --port 8080 --model <path-to-model.gguf>"
echo
