#!/usr/bin/env bash
# AI Platform — One-Time Linux Node Enrollment Script
#
# Usage:
#   sudo ./node-enroll.sh --token <SESSION_TOKEN> [--server <ORCHESTRATOR_IP:PORT>]
#
# Responsibilities:
#   1. Check for Ubuntu Linux environment
#   2. Verify presence of curl or wget (prints clear remediation if missing)
#   3. Dynamically identify physical Ethernet interface routing to Mac orchestrator
#   4. Ensure OpenSSH server is running and extract host public key
#   5. Gather hardware capability metrics (GPU, CPU, RAM)
#   6. Transmit enrollment payload to Mac enrollment listener
#   7. Authorize Mac cluster public key in non-root user's ~/.ssh/authorized_keys
#   8. Request DHCP lease renewal to acquire reserved permanent IP
#   9. Strictly verify reserved IP acquisition on physical interface

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ORCHESTRATOR_SERVER="10.42.0.1:8765"
ORCHESTRATOR_IP="10.42.0.1"
SESSION_TOKEN=""

# ── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token|-t)
      SESSION_TOKEN="$2"
      shift 2
      ;;
    --server|-s)
      ORCHESTRATOR_SERVER="$2"
      ORCHESTRATOR_IP="${ORCHESTRATOR_SERVER%%:*}"
      shift 2
      ;;
    --help|-h)
      echo "Usage: sudo $0 --token <SESSION_TOKEN> [--server <IP:PORT>]"
      exit 0
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      echo "Usage: sudo $0 --token <SESSION_TOKEN> [--server <IP:PORT>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SESSION_TOKEN" ]]; then
  echo "Error: --token <SESSION_TOKEN> is required." >&2
  echo "Usage: sudo $0 --token <SESSION_TOKEN>" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run with root privileges (sudo)." >&2
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AI Platform — Linux Node Enrollment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# ── 1. OS & Distribution Verification ────────────────────────────────────────
echo "→ Checking operating system..."
if [[ ! -f /etc/os-release ]]; then
  echo "Error: /etc/os-release not found. This node must run Ubuntu Linux." >&2
  exit 1
fi

DISTRO_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
DISTRO_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')

if [[ "$DISTRO_ID" != "ubuntu" && "$DISTRO_ID" != "debian" ]]; then
  echo "⚠️  Warning: Non-Ubuntu distribution detected ($DISTRO_NAME)."
  echo "   AI Platform officially targets Ubuntu 22.04 / 24.04 LTS."
fi
echo "✓ OS verified: $DISTRO_NAME"

# ── 2. HTTP Client Verification ──────────────────────────────────────────────
echo "→ Checking HTTP client..."
HTTP_CLIENT=""
if command -v curl >/dev/null 2>&1; then
  HTTP_CLIENT="curl"
elif command -v wget >/dev/null 2>&1; then
  HTTP_CLIENT="wget"
else
  echo
  echo "❌ ERROR: Missing required HTTP client (neither 'curl' nor 'wget' was found)." >&2
  echo "   Please install an HTTP client from Ubuntu installation media or copy via USB:" >&2
  echo "     sudo apt-get install -y wget  (or curl)" >&2
  echo
  exit 1
fi
echo "✓ Using HTTP client: $HTTP_CLIENT"

# Helper for HTTP POST JSON
http_post_json() {
  local url="$1"
  local json_data="$2"
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    curl -fsS --max-time 15 \
      -H "Content-Type: application/json" \
      -d "$json_data" \
      "$url"
  else
    wget -qO- --timeout=15 \
      --header="Content-Type: application/json" \
      --post-data="$json_data" \
      "$url"
  fi
}

# ── 3. Linux Non-Root User Detection ─────────────────────────────────────────
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  # Fallback to first UID >= 1000 user if SUDO_USER is not set
  TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd || echo "root")
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  TARGET_HOME="/home/$TARGET_USER"
fi
echo "✓ Managing SSH trust for user: $TARGET_USER ($TARGET_HOME)"

# ── 4. Dynamic Physical Ethernet Interface & Routing Auto-Configuration ───────
echo "→ Detecting active Ethernet interface connected to Mac ($ORCHESTRATOR_IP)..."

ROUTE_OUTPUT=$(ip route get "$ORCHESTRATOR_IP" 2>/dev/null || true)
DETECTED_DEV=$(echo "$ROUTE_OUTPUT" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)

if [[ -z "$DETECTED_DEV" ]]; then
  # Find physical non-wireless link
  for dev in $(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|podman|br-|veth|wlan|wlp|cni)/ {print $2}'); do
    ip link set dev "$dev" up 2>/dev/null || true
    if ip link show "$dev" 2>/dev/null | grep -qE "state UP|LOWER_UP"; then
      DETECTED_DEV="$dev"
      break
    fi
  done
fi

if [[ -z "$DETECTED_DEV" ]]; then
  echo "❌ Error: No active Ethernet interface connected to $ORCHESTRATOR_IP found." >&2
  echo "   Please check physical Ethernet cable connection to the Mac or private switch." >&2
  exit 1
fi

ip link set dev "$DETECTED_DEV" up 2>/dev/null || true

# Auto-configure default IPv4 route to Mac orchestrator NAT gateway if missing
if ! ip route | grep -q "default via $ORCHESTRATOR_IP"; then
  echo "  Configuring IPv4 default gateway via Mac orchestrator ($ORCHESTRATOR_IP)..."
  ip route replace default via "$ORCHESTRATOR_IP" dev "$DETECTED_DEV" 2>/dev/null || true
fi

# Auto-configure DNS resolver to use Mac orchestrator and public IPv4 fallback
mkdir -p /etc/apt/apt.conf.d 2>/dev/null || true
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4 2>/dev/null || true

if ! grep -q "$ORCHESTRATOR_IP" /etc/resolv.conf 2>/dev/null; then
  echo "  Configuring DNS resolver via Mac orchestrator ($ORCHESTRATOR_IP)..."
  printf "nameserver %s\nnameserver 8.8.8.8\n" "$ORCHESTRATOR_IP" > /etc/resolv.conf 2>/dev/null || true
fi

MAC_ADDR=$(ip link show dev "$DETECTED_DEV" | awk '/link\/ether/{print $2}' || echo "")
if [[ -z "$MAC_ADDR" ]]; then
  echo "❌ Error: Could not determine MAC address for interface '$DETECTED_DEV'." >&2
  exit 1
fi

CURRENT_IP=$(ip -4 -o addr show dev "$DETECTED_DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || echo "")
echo "✓ Detected interface: $DETECTED_DEV (MAC: $MAC_ADDR, Current IP: ${CURRENT_IP:-none})"

# ── 5. OpenSSH Server & Host Key Verification ────────────────────────────────
echo "→ Ensuring OpenSSH server is active..."
if ! command -v sshd >/dev/null 2>&1; then
  echo "  Installing openssh-server (IPv4 mode)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq -o Acquire::ForceIPv4=true && apt-get install -y -qq -o Acquire::ForceIPv4=true openssh-server >/dev/null || true
fi

systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl start ssh >/dev/null 2>&1 || systemctl start sshd >/dev/null 2>&1 || true

# Extract SSH host public key (prefer ed25519, fallback to ecdsa or rsa)
HOST_KEY=""
for key_type in ed25519 ecdsa rsa; do
  if [[ -f "/etc/ssh/ssh_host_${key_type}_key.pub" ]]; then
    HOST_KEY=$(cat "/etc/ssh/ssh_host_${key_type}_key.pub" | tr -d '\r\n')
    break
  fi
done

if [[ -z "$HOST_KEY" ]]; then
  echo "  Generating SSH host keys..."
  ssh-keygen -A >/dev/null 2>&1 || true
  if [[ -f "/etc/ssh/ssh_host_ed25519_key.pub" ]]; then
    HOST_KEY=$(cat "/etc/ssh/ssh_host_ed25519_key.pub" | tr -d '\r\n')
  fi
fi

if [[ -z "$HOST_KEY" ]]; then
  echo "❌ Error: Failed to find or generate SSH host public key." >&2
  exit 1
fi
echo "✓ SSH host key verified"

# ── 6. Hardware Capability Discovery ─────────────────────────────────────────
echo "→ Inspecting hardware capabilities..."

CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2}' | xargs || uname -m)
CPU_CORES=$(nproc 2>/dev/null || echo "1")
RAM_TOTAL_MB=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo "0")
RAM_TOTAL_GB=$(( (RAM_TOTAL_MB + 1023) / 1024 ))

GPUS_JSON="[]"
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_ROWS=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>/dev/null || true)
  if [[ -n "$GPU_ROWS" ]]; then
    GPUS_ARR=()
    while IFS=',' read -r g_name g_mem g_drv; do
      [[ -z "$g_name" ]] && continue
      g_name=$(echo "$g_name" | xargs)
      g_mem=$(echo "$g_mem" | xargs)
      g_drv=$(echo "$g_drv" | xargs)
      vram_gb=$(( (g_mem + 1023) / 1024 ))
      GPUS_ARR+=("{\"name\":\"$g_name\",\"vram_gb\":$vram_gb,\"driver_version\":\"$g_drv\",\"count\":1}")
    done <<< "$GPU_ROWS"
    if [[ ${#GPUS_ARR[@]} -gt 0 ]]; then
      IFS=,
      GPUS_JSON="[${GPUS_ARR[*]}]"
      unset IFS
    fi
  fi
fi

HOSTNAME_STR=$(hostname -s 2>/dev/null || hostname)
echo "  CPU: $CPU_MODEL ($CPU_CORES cores)"
echo "  RAM: ${RAM_TOTAL_GB} GB"
echo "  GPUs: $( [[ "$GPUS_JSON" == "[]" ]] && echo "None detected (CPU mode)" || echo "$GPUS_JSON" )"

# ── 7. Transmit Enrollment Handshake ─────────────────────────────────────────
echo "→ Registering with Mac orchestrator at http://${ORCHESTRATOR_SERVER}/api/enroll..."

ENROLL_PAYLOAD=$(cat <<EOF
{
  "token": "${SESSION_TOKEN}",
  "hostname": "${HOSTNAME_STR}",
  "mac_address": "${MAC_ADDR}",
  "ssh_user": "${TARGET_USER}",
  "ssh_host_key": "${HOST_KEY}",
  "interface": "${DETECTED_DEV}",
  "current_ip": "${CURRENT_IP}",
  "hardware": {
    "cpu": "${CPU_MODEL} (${CPU_CORES} cores)",
    "ram_gb": ${RAM_TOTAL_GB},
    "gpus": ${GPUS_JSON}
  }
}
EOF
)

RESPONSE=""
if ! RESPONSE=$(http_post_json "http://${ORCHESTRATOR_SERVER}/api/enroll" "$ENROLL_PAYLOAD"); then
  echo
  echo "❌ Error: Failed to connect to Mac enrollment server at http://${ORCHESTRATOR_SERVER}/api/enroll." >&2
  echo "   1. Ensure ./bootstrap.sh is running on the Mac Mini." >&2
  echo "   2. Ensure the Ethernet cable is securely connected." >&2
  echo "   3. Verify session token is valid and unexpired." >&2
  exit 1
fi

# Simple JSON parser helper in bash (without jq dependency requirement)
parse_json_field() {
  local json="$1"
  local field="$2"
  echo "$json" | sed -n "s/.*\"$field\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p"
}

STATUS=$(parse_json_field "$RESPONSE" "status")
if [[ "$STATUS" != "ok" ]]; then
  ERR_MSG=$(parse_json_field "$RESPONSE" "error")
  echo "❌ Enrollment rejected by orchestrator: ${ERR_MSG:-$RESPONSE}" >&2
  exit 1
fi

ASSIGNED_NODE_ID=$(parse_json_field "$RESPONSE" "node_id")
RESERVED_IP=$(parse_json_field "$RESPONSE" "reserved_ip")
CLUSTER_PUB_KEY=$(parse_json_field "$RESPONSE" "cluster_public_key")

if [[ -z "$ASSIGNED_NODE_ID" || -z "$RESERVED_IP" ]]; then
  echo "❌ Error: Invalid response structure received from orchestrator: $RESPONSE" >&2
  exit 1
fi

# ── 8. Authorize Mac Cluster Public Key ──────────────────────────────────────
echo "→ Installing Mac cluster public key in ~${TARGET_USER}/.ssh/authorized_keys..."

SSH_DIR="$TARGET_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"

AUTH_KEYS="$SSH_DIR/authorized_keys"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if [[ -n "$CLUSTER_PUB_KEY" ]]; then
  if ! grep -qF "$CLUSTER_PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "$CLUSTER_PUB_KEY" >> "$AUTH_KEYS"
  fi
  chown "$TARGET_USER:$TARGET_USER" "$AUTH_KEYS"
fi
echo "✓ SSH management channel authorized"

# ── 9. Trigger DHCP Renewal for Reserved IP ──────────────────────────────────
echo "→ Refreshing DHCP lease to apply reserved IP ($RESERVED_IP)..."

CONN_UUID=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$DETECTED_DEV" '$2==d{print $1; exit}')
if [[ -n "$CONN_UUID" ]]; then
  IPV4_METHOD=$(nmcli -t -f ipv4.method connection show uuid "$CONN_UUID" 2>/dev/null | cut -d: -f2)
  if [[ "$IPV4_METHOD" == "auto" ]]; then
    echo "  Reapplying NetworkManager connection ($CONN_UUID)..."
    nmcli connection up uuid "$CONN_UUID" 2>/dev/null || true
  else
    echo "  Switching NetworkManager connection ($CONN_UUID) to DHCP ('auto')..."
    nmcli connection modify uuid "$CONN_UUID" ipv4.method auto 2>/dev/null || true
    nmcli connection up uuid "$CONN_UUID" 2>/dev/null || true
  fi
elif command -v networkctl >/dev/null 2>&1; then
  echo "  Renewing DHCP lease via networkctl on $DETECTED_DEV..."
  networkctl renew "$DETECTED_DEV" 2>/dev/null || true
elif systemctl is-active --quiet NetworkManager; then
  echo "  Restarting NetworkManager service..."
  systemctl restart NetworkManager 2>/dev/null || true
elif systemctl is-active --quiet systemd-networkd; then
  echo "  Restarting systemd-networkd..."
  systemctl restart systemd-networkd 2>/dev/null || true
fi

# ── 10. Verify Reserved IP Acquisition ───────────────────────────────────────
echo "→ Verifying reserved IP ($RESERVED_IP) on $DETECTED_DEV..."

IP_ACQUIRED=false
for _ in {1..15}; do
  ACTIVE_IPS=$(ip -4 -o addr show dev "$DETECTED_DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  if echo "$ACTIVE_IPS" | grep -qw "$RESERVED_IP"; then
    IP_ACQUIRED=true
    break
  fi
  sleep 1
done

CURRENT_ACTIVE_IP=$(ip -4 -o addr show dev "$DETECTED_DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || echo "unknown")

if [[ "$IP_ACQUIRED" == "true" ]]; then
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  AI Platform — Node Enrollment Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Node ID          : ${ASSIGNED_NODE_ID}"
  echo "  DHCP-Reserved IP : ${RESERVED_IP} (VERIFIED ACTIVE)"
  echo "  Interface        : ${DETECTED_DEV} (${MAC_ADDR})"
  echo "  SSH User         : ${TARGET_USER}"
  echo "  Orchestrator     : ${ORCHESTRATOR_IP}"
  echo
  echo "  No further manual configuration required on this machine."
  echo "  The Mac Mini orchestrator will now remotely manage this node."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  exit 0
else
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  AI Platform — Enrollment Incomplete (Pending Reserved IP)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Node ID          : ${ASSIGNED_NODE_ID}"
  echo "  Assigned IP      : ${RESERVED_IP}"
  echo "  Current IP       : ${CURRENT_ACTIVE_IP} (NOT RESERVED IP)"
  echo "  Status           : enrolled_pending_ip"
  echo
  echo "  The node registered with orchestrator, but has not yet"
  echo "  acquired its reserved IP (${RESERVED_IP}) via DHCP."
  echo
  echo "  Please run:"
  echo "    sudo nmcli connection modify \$(nmcli -t -f UUID,DEVICE connection show --active | awk -F: '\$2==\"${DETECTED_DEV}\"{print \$1}') ipv4.method auto"
  echo "    sudo nmcli connection up \$(nmcli -t -f UUID,DEVICE connection show --active | awk -F: '\$2==\"${DETECTED_DEV}\"{print \$1}')"
  echo "  or reboot this machine to complete the network transition."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  exit 1
fi
