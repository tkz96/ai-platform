#!/usr/bin/env bash
# scripts/install/06a-networking.sh
# Phase: networking
#
# Fully manages the Mac Mini → Inference PC connection lifecycle:
#   1. Check  — physical link, IP config, reachability
#   2. Configure Mac side — static IP, IP forwarding, PF NAT
#   3. Configure node side — SSH in, set static IP, set gateway
#   4. Start llama-server on the node via SSH
#   5. Verify — end-to-end API health through LiteLLM
#
# The inference PC needs ONLY: a CLI Linux OS, llama.cpp, and the model.
# Nothing else needs to be installed on it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/networking.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Pause and wait for user to fix something, then retry
prompt_retry() {
  local message="$1"
  echo
  ui_warning "$message"
  ui_pause "Fix the issue above, then press Enter to retry..."
}

# Wait up to N seconds for a condition (function) to succeed
wait_for() {
  local label="$1" fn="$2" timeout="${3:-30}"
  local elapsed=0
  while ! $fn >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      return 1
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
    printf "."
  done
  echo
}

# ── Read inference node config from platform.yaml / secrets ──────────────────

# Check whether inference node is configured in platform.yaml
INFERENCE_USER=""
INFERENCE_LLAMA_BINARY=""
INFERENCE_MODEL_PATH=""

# Try to read from .install-state (persisted from a previous run)
STATE_FILE="${SCRIPT_DIR}/../../.install-state"
if [[ -f "$STATE_FILE" ]]; then
  INFERENCE_USER=$(grep '^inference_user=' "$STATE_FILE" | cut -d= -f2- || true)
  INFERENCE_LLAMA_BINARY=$(grep '^inference_llama_binary=' "$STATE_FILE" | cut -d= -f2- || true)
  INFERENCE_MODEL_PATH=$(grep '^inference_model_path=' "$STATE_FILE" | cut -d= -f2- || true)
fi

# Read LITELLM_MASTER_KEY from .env
MASTER_KEY=""
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
  MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' "$ENV_FILE" | cut -d= -f2-)
fi

# ─────────────────────────────────────────────────────────────────────────────

ui_header "Inference Node — Connection Setup"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1 — Physical link check
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 1 — Physical Ethernet Link"

ETH_IF=$(get_ethernet_interface)
if [[ -z "$ETH_IF" ]]; then
  ui_error "No built-in Ethernet interface found on this Mac."
  ui_fatal "This machine needs a built-in Ethernet port to connect to the inference PC."
fi
ui_info "Built-in Ethernet interface: $ETH_IF"

while ! interface_has_link "$ETH_IF"; do
  prompt_retry "No physical Ethernet link detected on $ETH_IF. Is the cable plugged in to the inference PC?"
done
ui_success "Physical link active on $ETH_IF"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 — Configure Mac Mini side (static IP, forwarding, NAT)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 2 — Mac Mini Network Configuration"

ui_step "Setting static IP ($MAC_MINI_IP) on $ETH_IF..."
if configure_mac_static_ip; then
  ui_success "Static IP $MAC_MINI_IP assigned to $ETH_IF"
else
  ui_warning "Could not configure static IP automatically. Continuing if already set."
fi

# Verify IP is actually on interface
if ! ifconfig "$ETH_IF" | grep -q "$MAC_MINI_IP"; then
  ui_error "IP $MAC_MINI_IP is not on $ETH_IF after configuration."
  ui_info  "Run: sudo ifconfig $ETH_IF $MAC_MINI_IP netmask 255.255.255.0"
  ui_fatal "Cannot proceed without the Mac Mini inference interface being configured."
fi

ui_step "Enabling kernel IP forwarding..."
if enable_ip_forwarding; then
  ui_success "IP forwarding enabled"
else
  ui_warning "Could not enable IP forwarding (sudo may be required)"
fi

ui_step "Configuring PF NAT for inference subnet (${INFERENCE_SUBNET})..."
if setup_pf_nat; then
  ui_success "PF NAT rule active — inference PC traffic will route via $(get_wan_interface)"
else
  ui_warning "PF NAT setup skipped (no WAN interface or sudo not available). Internet access from inference PC may not work."
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 3 — Discover and connect to inference PC via SSH
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 3 — Inference PC Discovery & SSH Access"

# Collect SSH credentials (prompt if not stored)
if [[ -z "$INFERENCE_USER" ]]; then
  INFERENCE_USER=$(ui_prompt_text "SSH username for inference PC" "ubuntu")
  # Persist
  if grep -q '^inference_user=' "$STATE_FILE" 2>/dev/null; then
    sed -i.bak "s|^inference_user=.*|inference_user=$INFERENCE_USER|" "$STATE_FILE"
  else
    echo "inference_user=$INFERENCE_USER" >> "$STATE_FILE"
  fi
fi
ui_info "SSH user: $INFERENCE_USER"

ui_step "Scanning for inference PC on $ETH_IF..."
DISCOVERED_IP=$(discover_node_ip || true)
if [[ -z "$DISCOVERED_IP" ]]; then
  ui_warning "No device discovered on the inference Ethernet link."
  ui_info "If the inference PC has no IP yet, SSH will not be possible."
  ui_info "Ensure the PC is powered on and its Ethernet port is active."
  DISCOVERED_IP=$(ui_prompt_text "Enter inference PC IP manually (or press Enter to retry discovery)")
fi

if [[ -z "$DISCOVERED_IP" ]]; then
  ui_fatal "Could not discover the inference PC. Check the cable and power state."
fi
ui_success "Inference PC discovered at: $DISCOVERED_IP"

# ── Test SSH Reachability ──
ui_step "Testing SSH access to $INFERENCE_USER@$DISCOVERED_IP..."
SSH_ATTEMPTS=0
while ! ssh_reachable "$INFERENCE_USER" "$DISCOVERED_IP"; do
  SSH_ATTEMPTS=$(( SSH_ATTEMPTS + 1 ))
  if (( SSH_ATTEMPTS >= 3 )); then
    ui_error "Cannot SSH into the inference PC after 3 attempts."
    ui_info "Things to check:"
    ui_info "  • SSH server is running: sudo systemctl status ssh"
    ui_info "  • SSH key is authorised: ssh-copy-id $INFERENCE_USER@$DISCOVERED_IP"
    ui_info "  • Firewall allows port 22: sudo ufw allow ssh"
    prompt_retry "Fix SSH access, then press Enter to retry."
    SSH_ATTEMPTS=0
  fi
  prompt_retry "SSH not reachable yet. Retrying (${SSH_ATTEMPTS}/3)..."
done
ui_success "SSH connection established to $INFERENCE_USER@$DISCOVERED_IP"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 4 — Configure inference PC network (set static 10.42.0.2/24)
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 4 — Configuring Inference PC Network"

if [[ "$DISCOVERED_IP" != "$NODE_IP" ]]; then
  ui_step "Detecting Ethernet interface on inference PC..."
  NODE_ETH=$(get_node_eth_interface "$INFERENCE_USER" "$DISCOVERED_IP" 2>/dev/null || true)
  if [[ -z "$NODE_ETH" ]]; then
    NODE_ETH=$(ui_prompt_text "Enter Ethernet interface name on inference PC" "eth0")
  fi
  ui_info "Inference PC interface: $NODE_ETH"

  ui_step "Assigning static IP $NODE_IP/24 and gateway $MAC_MINI_IP on inference PC..."
  if configure_node_network "$INFERENCE_USER" "$DISCOVERED_IP" "$NODE_ETH"; then
    ui_success "Network configured on inference PC"
  else
    ui_warning "Could not configure network remotely. You may need sudo access."
    prompt_retry "Manually set IP on the inference PC, then press Enter to continue."
  fi

  ui_step "Waiting for $NODE_IP to become reachable..."
  if ! ping -c 1 -W 3 "$NODE_IP" >/dev/null 2>&1; then
    prompt_retry "$NODE_IP is still unreachable. Ensure the network config was applied."
  fi
fi

ui_success "Inference PC is reachable at $NODE_IP"

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 5 — Start llama-server on inference PC
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 5 — Starting Inference Server (llama-server)"

# Check if already running
if node_api_healthy; then
  ui_success "llama-server is already running on $NODE_IP:$NODE_PORT"
else
  # Collect llama-server path if not stored
  if [[ -z "$INFERENCE_LLAMA_BINARY" ]]; then
    INFERENCE_LLAMA_BINARY=$(ui_prompt_text "Path to llama-server binary on inference PC" "/usr/local/bin/llama-server")
    if grep -q '^inference_llama_binary=' "$STATE_FILE" 2>/dev/null; then
      sed -i.bak "s|^inference_llama_binary=.*|inference_llama_binary=$INFERENCE_LLAMA_BINARY|" "$STATE_FILE"
    else
      echo "inference_llama_binary=$INFERENCE_LLAMA_BINARY" >> "$STATE_FILE"
    fi
  fi

  if [[ -z "$INFERENCE_MODEL_PATH" ]]; then
    INFERENCE_MODEL_PATH=$(ui_prompt_text "Path to GGUF model file on inference PC" "/models/qwen3.6-35b-a3b.gguf")
    if grep -q '^inference_model_path=' "$STATE_FILE" 2>/dev/null; then
      sed -i.bak "s|^inference_model_path=.*|inference_model_path=$INFERENCE_MODEL_PATH|" "$STATE_FILE"
    else
      echo "inference_model_path=$INFERENCE_MODEL_PATH" >> "$STATE_FILE"
    fi
  fi

  ui_info "Binary : $INFERENCE_LLAMA_BINARY"
  ui_info "Model  : $INFERENCE_MODEL_PATH"
  ui_step "Launching llama-server on inference PC..."

  LAUNCH_RESULT=$(start_llama_server "$INFERENCE_USER" "$NODE_IP" "$INFERENCE_LLAMA_BINARY" "$INFERENCE_MODEL_PATH" || true)
  if [[ "$LAUNCH_RESULT" == "failed" ]] || [[ -z "$LAUNCH_RESULT" ]]; then
    ui_error "llama-server failed to start. Check the model path and binary."
    ui_info "You can manually check logs on the inference PC:"
    ui_info "  ssh $INFERENCE_USER@$NODE_IP 'cat /tmp/llama-server.log'"
    prompt_retry "Fix the issue on the inference PC, then press Enter to continue."
  else
    ui_success "llama-server launched (background process on inference PC)"
  fi

  ui_step "Waiting for llama-server API to become healthy on $NODE_IP:$NODE_PORT..."
  printf "  Waiting"
  WAIT_SECS=0
  while ! node_api_healthy; do
    if (( WAIT_SECS >= 120 )); then
      echo
      ui_error "llama-server did not become healthy within 120 seconds."
      ui_info "Check logs: ssh $INFERENCE_USER@$NODE_IP 'cat /tmp/llama-server.log'"
      prompt_retry "Fix the issue, then press Enter to retry."
      WAIT_SECS=0
    fi
    sleep 3
    WAIT_SECS=$(( WAIT_SECS + 3 ))
    printf "."
  done
  echo
  ui_success "llama-server is healthy on $NODE_IP:$NODE_PORT"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 6 — End-to-end verification through LiteLLM
# ═════════════════════════════════════════════════════════════════════════════

ui_section "Stage 6 — End-to-End API Verification"

if [[ -z "$MASTER_KEY" ]]; then
  ui_warning "LiteLLM master key not found in .env — skipping full API test."
else
  ui_step "Sending test completion through LiteLLM → Caddy → llama-server..."
  RESPONSE=$(run_test_completion "$MASTER_KEY" 2>/dev/null || true)
  if [[ -z "$RESPONSE" ]]; then
    ui_warning "LiteLLM API test failed. The inference server may still be loading the model."
    ui_info "You can retry once model loading completes:"
    ui_info "  curl http://localhost:4000/v1/chat/completions \\"
    ui_info "    -H 'Authorization: Bearer $MASTER_KEY' \\"
    ui_info "    -d '{\"model\":\"qwen2.5-coder\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
  else
    ui_success "End-to-end API test passed!"
    echo
    echo -e "  ${DIM}Response preview:${RESET}"
    echo "$RESPONSE" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  msg = d['choices'][0]['message']['content']
  print('  ' + msg[:200])
except:
  print('  (raw response received)')
" 2>/dev/null || true
    echo
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# FINAL STATUS TABLE
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "  ${BOLD}Inference Node Status${RESET}"
echo -e "  ──────────────────────────────────────────"

# Physical link
if interface_has_link "$ETH_IF"; then
  echo -e "  ${GREEN}${SYM_OK}${RESET}  Physical link     $ETH_IF — ACTIVE"
else
  echo -e "  ${RED}${SYM_FAIL}${RESET}  Physical link     $ETH_IF — DOWN"
fi

# Ping to node
if ping -c 1 -W 2 "$NODE_IP" >/dev/null 2>&1; then
  echo -e "  ${GREEN}${SYM_OK}${RESET}  Inference PC IP   $NODE_IP — REACHABLE"
else
  echo -e "  ${YELLOW}${SYM_WARN}${RESET}  Inference PC IP   $NODE_IP — UNREACHABLE"
fi

# SSH
if ssh_reachable "$INFERENCE_USER" "$NODE_IP" 2>/dev/null; then
  echo -e "  ${GREEN}${SYM_OK}${RESET}  SSH               $INFERENCE_USER@$NODE_IP — OK"
else
  echo -e "  ${YELLOW}${SYM_WARN}${RESET}  SSH               $INFERENCE_USER@$NODE_IP — FAILED"
fi

# llama-server /health
if node_api_healthy; then
  echo -e "  ${GREEN}${SYM_OK}${RESET}  llama-server      http://$NODE_IP:$NODE_PORT — HEALTHY"
else
  echo -e "  ${YELLOW}${SYM_WARN}${RESET}  llama-server      http://$NODE_IP:$NODE_PORT — OFFLINE"
fi

# LiteLLM end-to-end
if [[ -n "$MASTER_KEY" ]] && [[ -n "$RESPONSE" ]]; then
  echo -e "  ${GREEN}${SYM_OK}${RESET}  LiteLLM API       http://localhost:4000 — OK"
fi

echo -e "  ──────────────────────────────────────────"
echo
