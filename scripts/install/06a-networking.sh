#!/usr/bin/env bash
# scripts/install/06a-networking.sh
# Phase: networking
#
# Manages Mac Mini Control Plane Private Network & Linux Node Provisioning:
#   1. Enumerate & safely select Mac Mini dedicated Ethernet interface
#   2. Configure Mac Mini static IP (10.42.0.1/24)
#   3. Start dnsmasq DHCP Server & PF NAT Gateway
#   4. Ensure Cluster Orchestrator SSH Key & Session Token are initialized
#   5. Handle Linux Node Enrollment (asynchronously in Web/non-interactive, or interactively in CLI)
#   6. Execute remote SSH provisioning and verification when nodes are enrolled

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/networking.sh"
source "$SCRIPT_DIR/lib/state.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/state"
SECRETS_DIR="$PROJECT_ROOT/secrets"
ENV_FILE="$PROJECT_ROOT/.env"

mkdir -p "$STATE_DIR"
mkdir -p "$SECRETS_DIR/ssh"

ui_header "Control Plane — Inference Cluster Network & Enrollment"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1 — Mac Mini Dedicated Ethernet Interface Selection
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 1 — Mac Mini Dedicated Ethernet NIC Selection"

IFACE_SELECTION=""
while true; do
  if IFACE_SELECTION=$(select_private_ethernet_interface); then
    break
  fi

  if is_noninteractive; then
    ui_error "Failed to select private Ethernet interface non-interactively."
    exit 1
  fi

  if ! ui_recoverable \
    "No physical Ethernet/Thunderbolt interfaces detected on this Mac." \
    "Connect a USB-to-Ethernet adapter or Thunderbolt Ethernet adapter, then press Enter to rescan."; then
    exit 1
  fi
done

ETH_IF=$(echo "$IFACE_SELECTION" | cut -d'|' -f1)
SELECTED_SVC=$(echo "$IFACE_SELECTION" | cut -d'|' -f2)

ui_info "Selected private Ethernet interface: ${BOLD}${ETH_IF}${RESET} (${SELECTED_SVC})"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 — Configure Mac Mini Static IP (10.42.0.1/24)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 2 — Mac Mini Static IP Configuration"

while true; do
  ui_step "Assigning $MAC_MINI_IP/24 to $ETH_IF ($SELECTED_SVC)..."
  configure_mac_inference_interface "$ETH_IF" || true

  if verify_mac_inference_interface "$ETH_IF"; then
    ui_success "Mac Mini inference interface $ETH_IF configured at $MAC_MINI_IP"
    break
  fi

  if is_noninteractive; then
    ui_error "Static IP $MAC_MINI_IP is not active on $ETH_IF."
    exit 1
  fi

  if ! ui_recoverable \
    "Static IP $MAC_MINI_IP is not active on $ETH_IF." \
    "Check Network settings for $SELECTED_SVC. Ensure it allows manual IP $MAC_MINI_IP (255.255.255.0).\n  Press Enter to retry."; then
    exit 1
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 3 — Start dnsmasq DHCP Server & PF NAT Gateway
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 3 — Mac DHCP Server & NAT Gateway"

while true; do
  ui_step "Starting dnsmasq DHCP server on $ETH_IF (Pool: 10.42.0.100–200)..."
  if start_mac_dhcp_server "$ETH_IF"; then
    ui_success "dnsmasq DHCP server active on $ETH_IF"
    break
  fi

  if is_noninteractive; then
    ui_error "Failed to start dnsmasq DHCP server on $ETH_IF."
    exit 1
  fi

  if ! ui_recoverable \
    "Failed to start dnsmasq DHCP server on $ETH_IF." \
    "Check that port 67 is not in use by another DHCP process.\n  Run: sudo lsof -i :67\n  Press Enter to retry."; then
    exit 1
  fi
done

while true; do
  ui_step "Enabling PF NAT and IP forwarding for private cluster..."
  if enable_mac_nat_gateway; then
    ui_success "PF NAT gateway and packet forwarding active"
    break
  fi

  if is_noninteractive; then
    ui_error "Failed to configure dedicated PF NAT gateway."
    exit 1
  fi

  if ! ui_recoverable \
    "Failed to configure dedicated PF NAT gateway." \
    "Check PF status with: sudo pfctl -s info\n  Press Enter to retry."; then
    exit 1
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 4 — Initialize Cluster SSH Key & Session Token
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 4 — Cluster Security Initialization"

# Ensure SSH keypair exists
CLUSTER_KEY="$SECRETS_DIR/ssh/cluster_orchestrator_key"
if [[ ! -f "$CLUSTER_KEY" ]]; then
  ui_step "Generating cluster orchestrator SSH keypair..."
  ssh-keygen -t ed25519 -f "$CLUSTER_KEY" -N "" -C "ai-platform-orchestrator" >/dev/null 2>&1
  chmod 600 "$CLUSTER_KEY"
  chmod 644 "${CLUSTER_KEY}.pub"
  ui_success "Cluster SSH keypair generated"
else
  ui_success "Cluster SSH keypair ready"
fi

# Ensure session token exists
TOKEN_FILE="$SECRETS_DIR/enrollment_token"
if [[ ! -f "$TOKEN_FILE" ]]; then
  SESSION_TOKEN="sk-enroll-$(openssl rand -hex 16 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n')"
  echo "$SESSION_TOKEN" > "$TOKEN_FILE"
  echo "$SESSION_TOKEN" > "$STATE_DIR/enrollment_token" 2>/dev/null || true
  chmod 600 "$TOKEN_FILE"
  ui_success "Fresh bootstrap session token generated"
else
  SESSION_TOKEN=$(cat "$TOKEN_FILE")
  echo "$SESSION_TOKEN" > "$STATE_DIR/enrollment_token" 2>/dev/null || true
  ui_success "Active bootstrap session token loaded"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 5 — Node Enrollment Instructions & Optional CLI Setup
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 5 — Linux Node Enrollment Configuration"

echo
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  AI Platform — Linux Inference Node Enrollment"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Gateway Interface: ${BOLD}${CYAN}${ETH_IF}${RESET} (${MAC_MINI_IP})"
echo -e "  Session Token:     ${BOLD}${CYAN}${SESSION_TOKEN}${RESET}"
echo -e ""
echo -e "  Run this on fresh Linux inference PCs to connect them:"
echo -e "    ${BOLD}wget -q http://${MAC_MINI_IP}:8765/node-enroll.sh -O node-enroll.sh${RESET}"
echo -e "    ${BOLD}chmod +x node-enroll.sh && sudo ./node-enroll.sh --token ${SESSION_TOKEN}${RESET}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

if is_noninteractive; then
  ui_success "Private network stack and gateway operational."
  ui_info "Node enrollment available on-demand via Web Dashboard or './bootstrap.sh connect-inference'."
  exit 0
fi

# Interactive CLI mode: Ask if operator wants to enroll nodes now
if ! ui_confirm "Do you want to start the enrollment server and connect Linux nodes now?" "N"; then
  ui_info "Skipping immediate node enrollment."
  ui_info "You can enroll inference nodes anytime by running: ./bootstrap.sh connect-inference"
  exit 0
fi

# ── Interactive Enrollment Listener ──────────────────────────────────────────

ENROLL_SERVER_PID=""
stop_enrollment_server_process() {
  if [[ -n "$ENROLL_SERVER_PID" ]] && ps -p "$ENROLL_SERVER_PID" >/dev/null 2>&1; then
    kill "$ENROLL_SERVER_PID" 2>/dev/null || true
    wait "$ENROLL_SERVER_PID" 2>/dev/null || true
  fi
  ENROLL_SERVER_PID=""
}

cleanup_enroll_server() {
  stop_enrollment_server_process
}
trap cleanup_enroll_server EXIT INT TERM

start_enrollment_server_process() {
  stop_enrollment_server_process
  (
    cd "$PROJECT_ROOT"
    export SESSION_TOKEN="$SESSION_TOKEN"
    uv run python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, '$PROJECT_ROOT')
from ai_platform.enrollment import make_enrollment_server
server = make_enrollment_server(Path('$PROJECT_ROOT'), host='$MAC_MINI_IP', port=8765)
server.serve_forever()
"
  ) &
  ENROLL_SERVER_PID=$!
  sleep 2
}

ui_step "Starting temporary enrollment HTTP server on $MAC_MINI_IP:8765..."
start_enrollment_server_process

ui_live_status_clear
while true; do
  ENROLLED_COUNT=0
  LEASE_COUNT=0
  if [[ -f "$STATE_DIR/nodes.yaml" ]] && command -v yq >/dev/null 2>&1; then
    ENROLLED_COUNT=$(yq '.nodes | length' "$STATE_DIR/nodes.yaml" 2>/dev/null || echo "0")
  fi
  if [[ -f "$STATE_DIR/dnsmasq.leases" ]]; then
    LEASE_COUNT=$(grep -c "^" "$STATE_DIR/dnsmasq.leases" 2>/dev/null || echo "0")
  fi

  link_str="${RED}disconnected${RESET}"
  if interface_has_link "$ETH_IF"; then
    link_str="${GREEN}connected${RESET}"
  fi

  ui_live_status \
    "  ${SYM_DOT} Physical link on $ETH_IF:  $link_str" \
    "  ${SYM_DOT} DHCP leases assigned:     ${BOLD}${LEASE_COUNT}${RESET} active" \
    "  ${SYM_DOT} Enrolled node(s):         ${BOLD}${GREEN}${ENROLLED_COUNT}${RESET}" \
    "" \
    "  ${DIM}Press Enter to proceed with enrolled nodes | S to skip | Q to quit${RESET}"

  key=""
  if read -rsn1 -t 5 key; then
    case "$key" in
      "")  # Enter key
        ui_live_status_clear
        if (( ENROLLED_COUNT > 0 )); then
          echo
          ui_success "Proceeding with $ENROLLED_COUNT enrolled node(s)."
          (cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes list 2>/dev/null || true)
          break
        else
          echo
          ui_warning "No nodes enrolled yet."
          if ui_confirm "Do you want to proceed without enrolling any nodes now?" "N"; then
            break
          fi
          ui_live_status_clear
        fi
        ;;
      s|S)
        ui_live_status_clear
        echo
        ui_warning "Skipping node enrollment. You can enroll later via: ./bootstrap.sh connect-inference"
        break
        ;;
      q|Q)
        ui_live_status_clear
        cleanup_enroll_server
        ui_info "Exiting at user request."
        exit 0
        ;;
    esac
  fi
done

cleanup_enroll_server
trap - EXIT INT TERM
ui_success "Enrollment server stopped"

# Provision enrolled nodes if any
ENROLLED_COUNT=0
if [[ -f "$STATE_DIR/nodes.yaml" ]] && command -v yq >/dev/null 2>&1; then
  ENROLLED_COUNT=$(yq '.nodes | length' "$STATE_DIR/nodes.yaml" 2>/dev/null || echo "0")
fi

if (( ENROLLED_COUNT > 0 )); then
  ui_section "Stage 6 — Remote SSH Node Provisioning"
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes provision) || true
  ui_section "Stage 7 — Multi-Node Cluster Verification"
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes verify) || true
fi

echo
ui_success "Inference cluster networking phase completed."
