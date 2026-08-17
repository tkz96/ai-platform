#!/usr/bin/env bash
# scripts/install/06a-networking.sh
# Phase: networking
#
# Manages the Mac Mini Control Plane → Linux Inference PC private link:
#   1. Enumerate & safely select Mac Mini physical Ethernet interface
#   2. Configure Mac Mini static IP (10.42.0.1/24)
#   3. Verify Inference PC reachability (10.42.0.2)
#   4. Multi-stage verification:
#      - Mac Host TCP (10.42.0.2:8080)
#      - Mac Host HTTP health (/health)
#      - Podman VM container HTTP health
#      - LiteLLM container connectivity
#      - LiteLLM end-to-end model completion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/networking.sh"
source "$SCRIPT_DIR/lib/state.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/.install-state"
ENV_FILE="$PROJECT_ROOT/.env"

# ── Read Config ──────────────────────────────────────────────────────────────

INFERENCE_HOST="10.42.0.2"
INFERENCE_PORT="8080"
INFERENCE_HEALTH_ENDPOINT="/health"
MASTER_KEY=""

if [[ -f "$ENV_FILE" ]]; then
  INFERENCE_HOST=$(grep '^INFERENCE_HOST=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "10.42.0.2")
  INFERENCE_PORT=$(grep '^INFERENCE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "8080")
  INFERENCE_HEALTH_ENDPOINT=$(grep '^INFERENCE_HEALTH_ENDPOINT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "/health")
  MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")
  [[ -z "$INFERENCE_HOST" ]] && INFERENCE_HOST="10.42.0.2"
  [[ -z "$INFERENCE_PORT" ]] && INFERENCE_PORT="8080"
  [[ -z "$INFERENCE_HEALTH_ENDPOINT" ]] && INFERENCE_HEALTH_ENDPOINT="/health"
fi

ui_header "Control Plane — Inference Node Network Setup"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1 — Hardware-Port Interface Enumeration & Selection (Mac Mini)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 1 — Mac Mini Ethernet Interface Selection"

CANDIDATES_RAW=$(list_physical_ethernet_candidates)
if [[ -z "$CANDIDATES_RAW" ]]; then
  ui_error "No physical Ethernet/Thunderbolt interfaces found on this Mac."
  ui_fatal "A dedicated physical Ethernet interface is required to connect to the inference PC."
fi

WAN_IF=$(get_wan_interface)
ETH_IF=""
SAVED_IF=$(state_get_phase "inference_mac_iface" 2>/dev/null || echo "")
if [[ "$SAVED_IF" == "not_started" || "$SAVED_IF" == "null" ]]; then
  SAVED_IF=""
fi

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
  # Multiple candidates: prompt operator
  SELECTED_NUM=$(ui_prompt_text "Select the Ethernet interface for the private inference link (1-$CANDIDATE_COUNT)" "1")
  SEL_INDEX=$(( SELECTED_NUM - 1 ))
  if (( SEL_INDEX < 0 || SEL_INDEX >= CANDIDATE_COUNT )); then
    ui_fatal "Invalid selection: $SELECTED_NUM"
  fi
  SELECTED_DEV="${PARSED_DEVS[$SEL_INDEX]}"
  SELECTED_SVC="${PARSED_SVCS[$SEL_INDEX]}"
fi

# ── Default Route Disruption Guard ──
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
  ui_warning "No physical link detected on $ETH_IF. Is the Ethernet cable connected to the inference PC?"
  ui_pause "Connect the cable and press Enter to retry link detection..."
done
ui_success "Physical carrier active on $ETH_IF"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 — Configure Mac Mini Static IP (10.42.0.1/24)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 2 — Mac Mini Static IP Configuration"

ui_step "Assigning $MAC_MINI_IP/24 to $ETH_IF ($SELECTED_SVC)..."
if configure_mac_inference_interface "$ETH_IF"; then
  ui_success "Static IP $MAC_MINI_IP assigned to $ETH_IF"
else
  ui_warning "Automatic IP assignment via networksetup returned non-zero. Verifying..."
fi

if ! verify_mac_inference_interface "$ETH_IF"; then
  ui_error "Static IP $MAC_MINI_IP is not active on $ETH_IF."
  ui_info "You may manually run: sudo ifconfig $ETH_IF $MAC_MINI_IP netmask 255.255.255.0"
  ui_fatal "Cannot continue without Mac Mini inference interface configured."
fi
ui_success "Mac Mini inference interface $ETH_IF configured at $MAC_MINI_IP"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 3 — Verify Inference Node Reachability (10.42.0.2)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 3 — Inference Node Reachability"

ui_step "Pinging Inference PC at $INFERENCE_HOST..."
PING_ATTEMPTS=0
while ! ping -c 1 -W 2 "$INFERENCE_HOST" >/dev/null 2>&1; do
  PING_ATTEMPTS=$(( PING_ATTEMPTS + 1 ))
  if (( PING_ATTEMPTS >= 3 )); then
    echo
    ui_warning "Inference PC ($INFERENCE_HOST) is not responding to ping."
    echo
    ui_info "If this is a fresh setup, log into your Linux inference PC and run the node bootstrap:"
    ui_info "  sudo ./scripts/inference/bootstrap-node.sh"
    echo
    ui_info "Options:"
    ui_info "  1) Press Enter to retry pinging $INFERENCE_HOST"
    ui_info "  2) Or enter an existing management LAN IP/host to bootstrap via SSH"
    MGMT_HOST=$(ui_prompt_text "Management SSH host (or press Enter to retry ping)")
    if [[ -n "$MGMT_HOST" ]]; then
      MGMT_USER=$(ui_prompt_text "SSH user for $MGMT_HOST" "ubuntu")
      ui_step "Copying bootstrap-node.sh to $MGMT_USER@$MGMT_HOST..."
      scp -o ConnectTimeout=8 "$SCRIPT_DIR/../inference/bootstrap-node.sh" "${MGMT_USER}@${MGMT_HOST}:/tmp/bootstrap-node.sh"
      ui_step "Executing remote bootstrap on $MGMT_HOST..."
      ssh -t -o ConnectTimeout=8 "${MGMT_USER}@${MGMT_HOST}" "sudo bash /tmp/bootstrap-node.sh" || true
    fi
    PING_ATTEMPTS=0
  fi
  sleep 2
done

ui_success "Inference PC reached at $INFERENCE_HOST"

# Optional peer MAC diagnostic
PEER_MAC=$(show_peer_mac_diagnostic "$INFERENCE_HOST")
if [[ -n "$PEER_MAC" ]]; then
  ui_info "Inference node MAC address (ARP): $PEER_MAC"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 4 — Multi-Stage Staged Verification
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 4 — Multi-Stage End-to-End Verification"

# ── Test 1: Mac Host TCP Reachability ──
ui_step "Test 1/5: Mac Host → TCP ${INFERENCE_HOST}:${INFERENCE_PORT}..."
if check_host_tcp_connection "$INFERENCE_HOST" "$INFERENCE_PORT"; then
  ui_success "Mac host TCP connection established (port $INFERENCE_PORT open)"
else
  ui_error "TCP port $INFERENCE_PORT is closed on $INFERENCE_HOST."
  ui_info "Ensure llama-server is running on the inference PC: ss -lntp | grep :$INFERENCE_PORT"
  ui_warning "Continuing checks to collect full diagnostic report."
fi

# ── Test 2: Mac Host HTTP Health Endpoint ──
ui_step "Test 2/5: Mac Host → HTTP ${INFERENCE_HOST}:${INFERENCE_PORT}${INFERENCE_HEALTH_ENDPOINT}..."
if check_host_http_health "$INFERENCE_HOST" "$INFERENCE_PORT" "$INFERENCE_HEALTH_ENDPOINT"; then
  ui_success "Mac host HTTP health check passed"
else
  ui_warning "Mac host HTTP health endpoint not responding (model may still be loading)."
fi

# ── Test 3: Podman VM Container Probe ──
ui_step "Test 3/5: Podman VM Container → HTTP ${INFERENCE_HOST}:${INFERENCE_PORT}${INFERENCE_HEALTH_ENDPOINT}..."
if check_podman_vm_health "$INFERENCE_HOST" "$INFERENCE_PORT" "$INFERENCE_HEALTH_ENDPOINT"; then
  ui_success "Podman VM container network path verified"
else
  ui_warning "Podman VM container failed to reach inference endpoint."
  ui_info "Check Podman VM routing: podman machine info"
fi

# ── Test 4: LiteLLM Container Connectivity ──
ui_step "Test 4/5: LiteLLM Container → Inference backend..."
if check_litellm_container_connectivity "$INFERENCE_HOST" "$INFERENCE_PORT" "$INFERENCE_HEALTH_ENDPOINT"; then
  ui_success "LiteLLM container connectivity verified"
else
  ui_info "LiteLLM container check skipped or container not started yet."
fi

# ── Test 5: Full Chat Completion ──
if [[ -n "$MASTER_KEY" ]]; then
  ui_step "Test 5/5: Sending test chat completion (LiteLLM → llama-server → Qwen)..."
  RESP=$(run_test_completion "$MASTER_KEY" 2>/dev/null || true)
  if [[ -n "$RESP" ]] && echo "$RESP" | grep -q "choices"; then
    ui_success "End-to-end model completion test passed!"
  else
    ui_info "End-to-end completion pending service startup."
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY TABLE
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "  ${BOLD}Network Topology & Inference Status${RESET}"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  Mac Mini Interface   : $ETH_IF ($SELECTED_SVC) — $MAC_MINI_IP/24"
echo -e "  Inference Node       : $INFERENCE_HOST:$INFERENCE_PORT"
echo -e "  Physical Carrier     : $( interface_has_link "$ETH_IF" && echo "${GREEN}ACTIVE${RESET}" || echo "${RED}DOWN${RESET}" )"
echo -e "  Node Reachability    : $( ping -c 1 -W 2 "$INFERENCE_HOST" >/dev/null 2>&1 && echo "${GREEN}REACHABLE${RESET}" || echo "${RED}UNREACHABLE${RESET}" )"
echo -e "  TCP Port $INFERENCE_PORT       : $( check_host_tcp_connection "$INFERENCE_HOST" "$INFERENCE_PORT" && echo "${GREEN}OPEN${RESET}" || echo "${YELLOW}CLOSED/PENDING${RESET}" )"
echo -e "  HTTP Health Endpoint : $( check_host_http_health "$INFERENCE_HOST" "$INFERENCE_PORT" "$INFERENCE_HEALTH_ENDPOINT" && echo "${GREEN}OK${RESET}" || echo "${YELLOW}PENDING${RESET}" )"
echo -e "  Podman VM Path       : $( check_podman_vm_health "$INFERENCE_HOST" "$INFERENCE_PORT" "$INFERENCE_HEALTH_ENDPOINT" && echo "${GREEN}OK${RESET}" || echo "${YELLOW}PENDING${RESET}" )"
echo -e "  ──────────────────────────────────────────────────────────"
echo
