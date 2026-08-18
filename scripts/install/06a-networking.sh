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

while true; do
  CANDIDATES_RAW=$(list_physical_ethernet_candidates)
  if [[ -n "$CANDIDATES_RAW" ]]; then
    break
  fi
  if ! ui_recoverable \
    "No physical Ethernet/Thunderbolt interfaces detected on this Mac." \
    "Connect a USB-to-Ethernet adapter or Thunderbolt Ethernet adapter, then press Enter to rescan."; then
    exit 1
  fi
done

WAN_IF=$(get_wan_interface)
ETH_IF=""
SELECTED_SVC=""
SELECTED_DEV=""

while true; do
  CANDIDATES_RAW=$(list_physical_ethernet_candidates)
  IFS=$'\n' read -rd '' -a CANDIDATE_LINES <<< "$CANDIDATES_RAW" || true
  CANDIDATE_COUNT="${#CANDIDATE_LINES[@]}"

  ui_info "Found $CANDIDATE_COUNT physical Ethernet port(s):"

  declare -a PARSED_DEVS=()
  declare -a PARSED_SVCS=()
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
      ui_warning "Invalid selection: $SELECTED_NUM. Please enter a number between 1 and $CANDIDATE_COUNT."
      continue
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
      ui_info "Please select a different Ethernet/Thunderbolt NIC."
      continue
    fi
  fi

  ETH_IF="$SELECTED_DEV"
  break
done

# Verify physical link carrier
while ! interface_has_link "$ETH_IF"; do
  echo
  ui_warning "No physical link detected on $ETH_IF. Is the Ethernet cable connected to the private switch?"
  if ! ui_recoverable \
    "Physical link inactive on $ETH_IF." \
    "Connect the Ethernet cable from this Mac ($ETH_IF) to the private switch or Linux PC, then press Enter to re-check."; then
    exit 1
  fi
done
ui_success "Physical carrier active on $ETH_IF"

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

# Invalidate any pre-existing session token and generate a fresh one
TOKEN_FILE="$SECRETS_DIR/enrollment_token"
rm -f "$TOKEN_FILE"
SESSION_TOKEN="sk-enroll-$(openssl rand -hex 16 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n')"
echo "$SESSION_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
ui_success "Fresh bootstrap session token generated"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 5 & 6 — Temporary Enrollment Server & Operator Prompt
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 5 — Linux Node One-Time Enrollment"

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
  rm -f "$TOKEN_FILE"
}
trap cleanup_enroll_server EXIT INT TERM

start_enrollment_server_process() {
  stop_enrollment_server_process
  mkdir -p "$SECRETS_DIR" "$STATE_DIR" 2>/dev/null || true
  echo "$SESSION_TOKEN" > "$TOKEN_FILE"
  echo "$SESSION_TOKEN" > "$STATE_DIR/enrollment_token"
  chmod 600 "$TOKEN_FILE" "$STATE_DIR/enrollment_token" 2>/dev/null || true
  (
    cd "$PROJECT_ROOT"
    export SESSION_TOKEN="$SESSION_TOKEN"
    uv run python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, '$PROJECT_ROOT')
from platform.enrollment import make_enrollment_server
server = make_enrollment_server(Path('$PROJECT_ROOT'), host='$MAC_MINI_IP', port=8765)
server.serve_forever()
"
  ) &
  ENROLL_SERVER_PID=$!
  sleep 2
}

ui_step "Starting temporary enrollment HTTP server on $MAC_MINI_IP:8765..."
start_enrollment_server_process

ui_step "Verifying enrollment server and DHCP readiness..."
while ! smoke_test_mac_network_services; do
  diag_server="${RED}crashed / not running${RESET}"
  diag_dhcp="${RED}not running${RESET}"

  if [[ -n "$ENROLL_SERVER_PID" ]] && ps -p "$ENROLL_SERVER_PID" >/dev/null 2>&1; then
    diag_server="${GREEN}process running (endpoint failing)${RESET}"
  fi

  pid_file="/tmp/ai-platform-dnsmasq.pid"
  if [[ -f "$pid_file" ]]; then
    dpid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$dpid" ]] && sudo kill -0 "$dpid" 2>/dev/null; then
      diag_dhcp="${GREEN}running (PID $dpid)${RESET}"
    fi
  fi

  echo
  echo -e "  ${RED}${BOLD}━━━ Enrollment Server Not Ready ━━━${RESET}"
  echo -e "  ${SYM_DOT} Enrollment HTTP server: $diag_server"
  echo -e "  ${SYM_DOT} dnsmasq DHCP server:    $diag_dhcp"
  echo
  echo -e "  ${BOLD}Options:${RESET}"
  echo -e "  [R] ${GREEN}Retry${RESET}  — Restart enrollment server and try again"
  echo -e "  [S] ${YELLOW}Skip${RESET}   — Deploy Mac services now, enroll nodes later"
  echo -e "                 (run: ./bootstrap.sh connect-inference)"
  echo -e "  [Q] ${RED}Quit${RESET}   — Exit the installer"
  echo

  key=""
  read -rsn1 key
  case "$key" in
    r|R|"")
      ui_step "Restarting enrollment server..."
      start_enrollment_server_process
      ;;
    s|S)
      ui_warning "Skipping node enrollment. Mac services will deploy now."
      ENROLLMENT_SKIPPED=true
      break
      ;;
    q|Q)
      cleanup_enroll_server
      ui_info "Exiting at user request."
      exit 1
      ;;
  esac
done

if [[ "$ENROLLMENT_SKIPPED" != "true" ]]; then
  ui_success "Enrollment listener running and verified on http://$MAC_MINI_IP:8765"

  echo
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  AI Platform — Linux Inference Node Enrollment"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  Session Token: ${BOLD}${CYAN}${SESSION_TOKEN}${RESET}"
  echo -e ""
  echo -e "  Run this on every fresh Linux inference PC:"
  echo -e ""
  echo -e "  ${BOLD}Option A — wget (available on fresh Ubuntu):${RESET}"
  echo -e "    wget -q http://${MAC_MINI_IP}:8765/node-enroll.sh -O node-enroll.sh"
  echo -e ""
  echo -e "  ${BOLD}Option B — curl (if installed):${RESET}"
  echo -e "    curl -fsS http://${MAC_MINI_IP}:8765/node-enroll.sh -o node-enroll.sh"
  echo -e ""
  echo -e "  ${BOLD}Then execute:${RESET}"
  echo -e "    chmod +x node-enroll.sh"
  echo -e "    sudo ./node-enroll.sh --token ${SESSION_TOKEN}"
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e ""

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
              ENROLLMENT_SKIPPED=true
              break
            fi
            ui_live_status_clear
          fi
          ;;
        s|S)
          ui_live_status_clear
          echo
          ui_warning "Skipping node enrollment. You can enroll later via: ./bootstrap.sh connect-inference"
          ENROLLMENT_SKIPPED=true
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
fi

# Stop enrollment server and clean up token
cleanup_enroll_server
trap - EXIT INT TERM
ui_success "Enrollment server stopped and session token invalidated"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 6 & 7 — Centralized Remote Node Provisioning & Verification
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$ENROLLMENT_SKIPPED" != "true" ]]; then
  ui_section "Stage 6 — Remote SSH Node Provisioning"
  ui_step "Executing remote provisioning across all enrolled nodes..."
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes provision) || true
  ui_success "Node provisioning cycle completed"

  ui_section "Stage 7 — Multi-Node Cluster Verification"
  (cd "$PROJECT_ROOT" && uv run python bootstrap.py nodes verify) || true
else
  ui_info "Node provisioning skipped. Run './bootstrap.sh connect-inference' when nodes are ready."
fi

echo
ui_success "Inference cluster networking phase completed."
