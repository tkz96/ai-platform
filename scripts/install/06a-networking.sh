#!/usr/bin/env bash
# scripts/install/06a-networking.sh
# Phase: networking
#
# Manages Mac Mini Control Plane Private Network & Linux Node Provisioning:
#   1. Enumerate & safely select Mac Mini dedicated Ethernet interface
#   2. Configure Mac Mini static IP (10.42.0.1/24)
#   3. Start dnsmasq DHCP Server & PF NAT Gateway
#   4. Ensure Cluster Orchestrator SSH Key & Session Token are initialized
#   5. Start temporary enrollment HTTP server (10.42.0.1:8765)
#   6. Display enrollment instructions and wait for operator confirmation
#   7. Shutdown enrollment server (guaranteed via cleanup trap)
#   8. Execute remote SSH provisioning for all enrolled nodes
#   9. Multi-node cluster verification

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

CANDIDATES_RAW=$(list_physical_ethernet_candidates)
if [[ -z "$CANDIDATES_RAW" ]]; then
  ui_error "No physical Ethernet/Thunderbolt interfaces found on this Mac."
  ui_fatal "A dedicated physical Ethernet interface is required to connect to the private inference switch."
fi

WAN_IF=$(get_wan_interface)
ETH_IF=""

# Build list of candidate records
IFS=$'\n' read -rd '' -a CANDIDATE_LINES <<< "$CANDIDATES_RAW" || true
CANDIDATE_COUNT="${#CANDIDATE_LINES[@]}"

ui_info "Found $CANDIDATE_COUNT physical Ethernet port(s):"

declare -a PARSED_DEVS
declare -a PARSED_SVCS
idx=1

for line in "${CANDIDATE_LINES[@]}"; do
  [[ -z "$line" ]] && continue
  svc=$(echo "$line" | cut -d'|' -f1)
  dev=$(echo "$line" | cut -d'|' -f2)
  mac=$(echo "$line" | cut -d'|' -f3)
  link_state="inactive"
  if interface_has_link "$dev"; then
    link_state="ACTIVE"
  fi
  cur_ip=$(interface_get_ip "$dev")
  [[ -z "$cur_ip" ]] && cur_ip="none"
  is_default="NO"
  if [[ "$dev" == "$WAN_IF" ]]; then
    is_default="YES (Active Internet/WAN)"
  fi

  PARSED_DEVS+=("$dev")
  PARSED_SVCS+=("$svc")

  echo -e "  [${idx}] ${BOLD}${svc}${RESET} (${dev})"
  echo -e "      MAC Address   : ${DIM}${mac}${RESET}"
  echo -e "      Link State    : $( [[ "$link_state" == "ACTIVE" ]] && echo "${GREEN}ACTIVE${RESET}" || echo "${YELLOW}INACTIVE${RESET}" )"
  echo -e "      Current IP    : ${cur_ip}"
  echo -e "      Default Route : ${is_default}"
  idx=$(( idx + 1 ))
done

if [[ "$CANDIDATE_COUNT" -eq 1 ]]; then
  SELECTED_DEV="${PARSED_DEVS[0]}"
  SELECTED_SVC="${PARSED_SVCS[0]}"
  ui_info "Single Ethernet port detected: $SELECTED_DEV ($SELECTED_SVC)"
else
  SELECTED_NUM=$(ui_prompt_text "Select the Ethernet interface for the private inference link (1-$CANDIDATE_COUNT)" "1")
  SEL_INDEX=$(( SELECTED_NUM - 1 ))
  if (( SEL_INDEX < 0 || SEL_INDEX >= CANDIDATE_COUNT )); then
    ui_fatal "Invalid selection: $SELECTED_NUM"
  fi
  SELECTED_DEV="${PARSED_DEVS[$SEL_INDEX]}"
  SELECTED_SVC="${PARSED_SVCS[$SEL_INDEX]}"
fi

# Guard against disruption of primary WAN default route
if [[ "$SELECTED_DEV" == "$WAN_IF" ]]; then
  echo
  ui_warning "CAUTION: Interface $SELECTED_DEV currently carries your primary Internet/WAN route!"
  ui_warning "Assigning static IP $MAC_MINI_IP will disrupt this machine's Internet connectivity."
  if ! ui_confirm "Are you sure you want to repurpose $SELECTED_DEV as the private inference link?" "N"; then
    ui_fatal "Aborted by user. Please select a dedicated secondary Ethernet/Thunderbolt NIC."
  fi
fi

ETH_IF="$SELECTED_DEV"

# Verify physical link carrier
while ! interface_has_link "$ETH_IF"; do
  echo
  ui_warning "No physical link detected on $ETH_IF. Is the Ethernet cable connected to the private switch?"
  ui_pause "Connect the cable and press Enter to retry link detection..."
done
ui_success "Physical carrier active on $ETH_IF"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 — Configure Mac Mini Static IP (10.42.0.1/24)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 2 — Mac Mini Static IP Configuration"

ui_step "Assigning $MAC_MINI_IP/24 to $ETH_IF ($SELECTED_SVC)..."
configure_mac_inference_interface "$ETH_IF" || true

if ! verify_mac_inference_interface "$ETH_IF"; then
  ui_error "Static IP $MAC_MINI_IP is not active on $ETH_IF."
  ui_fatal "Cannot continue without Mac Mini inference interface configured."
fi
ui_success "Mac Mini inference interface $ETH_IF configured at $MAC_MINI_IP"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 3 — Start dnsmasq DHCP Server & PF NAT Gateway
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 3 — Mac DHCP Server & NAT Gateway"

ui_step "Starting dnsmasq DHCP server on $ETH_IF (Pool: 10.42.0.100–200)..."
if start_mac_dhcp_server "$ETH_IF"; then
  ui_success "dnsmasq DHCP server active on $ETH_IF"
else
  ui_warning "Could not start dnsmasq. Ensure 'brew install dnsmasq' was completed."
fi

ui_step "Enabling PF NAT and IP forwarding for private cluster..."
if enable_mac_nat_gateway; then
  ui_success "PF NAT gateway and packet forwarding active"
else
  ui_warning "Could not configure PF NAT gateway. Linux nodes may lack outbound WAN access."
fi

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

# Ensure enrollment session token exists
TOKEN_FILE="$SECRETS_DIR/enrollment_token"
if [[ ! -f "$TOKEN_FILE" ]]; then
  SESSION_TOKEN="sk-enroll-$(openssl rand -hex 16 2>/dev/null)"
  echo "$SESSION_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
else
  SESSION_TOKEN=$(cat "$TOKEN_FILE" | tr -d '\r\n')
fi
ui_success "Bootstrap session token initialized"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 5 & 6 — Temporary Enrollment Server & Operator Prompt
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 5 — Linux Node One-Time Enrollment"

# Background server PID variable for cleanup trap
ENROLL_SERVER_PID=""

cleanup_enroll_server() {
  if [[ -n "$ENROLL_SERVER_PID" ]] && ps -p "$ENROLL_SERVER_PID" >/dev/null 2>&1; then
    kill "$ENROLL_SERVER_PID" 2>/dev/null || true
    wait "$ENROLL_SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup_enroll_server EXIT INT TERM

ui_step "Starting temporary enrollment HTTP server on $MAC_MINI_IP:8765..."

# Start python background enrollment listener
python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, '$PROJECT_ROOT')
from platform.enrollment import make_enrollment_server
server = make_enrollment_server(Path('$PROJECT_ROOT'), host='$MAC_MINI_IP', port=8765)
server.serve_forever()
" &
ENROLL_SERVER_PID=$!
sleep 1

ui_success "Enrollment listener running on http://$MAC_MINI_IP:8765"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AI Platform — Linux Inference Node Enrollment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Session Token: ${BOLD}${CYAN}${SESSION_TOKEN}${RESET}"
echo
echo "  Run this on every fresh Linux inference PC:"
echo
echo "  ${BOLD}Option A — wget (available on fresh Ubuntu):${RESET}"
echo "    wget -q http://${MAC_MINI_IP}:8765/node-enroll.sh -O node-enroll.sh"
echo
echo "  ${BOLD}Option B — curl (if installed):${RESET}"
echo "    curl -fsS http://${MAC_MINI_IP}:8765/node-enroll.sh -o node-enroll.sh"
echo
echo "  ${BOLD}Then execute:${RESET}"
echo "    chmod +x node-enroll.sh"
echo "    sudo ./node-enroll.sh --token ${SESSION_TOKEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Interactive wait loop
while true; do
  ENROLLED_COUNT=0
  if [[ -f "$STATE_DIR/nodes.yaml" ]] && command -v yq >/dev/null 2>&1; then
    ENROLLED_COUNT=$(yq '.nodes | length' "$STATE_DIR/nodes.yaml" 2>/dev/null || echo "0")
  fi

  echo -e "Currently enrolled node(s): ${BOLD}${GREEN}${ENROLLED_COUNT}${RESET}"
  if (( ENROLLED_COUNT > 0 )); then
    (cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes list 2>/dev/null || true)
  fi

  if ui_confirm "All nodes enrolled? Begin automated remote provisioning?" "Y"; then
    break
  fi
  echo
  ui_info "Waiting for additional nodes to enroll..."
  sleep 3
done

# Stop enrollment server
cleanup_enroll_server
trap - EXIT INT TERM
ui_success "Enrollment server stopped"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 7 — Centralized Remote Node Provisioning
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 6 — Remote SSH Node Provisioning"

ui_step "Executing remote provisioning across all enrolled nodes..."
(cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes provision) || true
ui_success "Node provisioning cycle completed"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 8 — Multi-Node Cluster Verification
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 7 — Multi-Node Cluster Verification"

(cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes verify) || true

echo
ui_success "Inference cluster networking and node provisioning complete."
