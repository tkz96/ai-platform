#!/usr/bin/env bash
# Phase 6a: Networking and NAT Setup for Inference Subnet (10.42.0.0/24)

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/networking.sh"

ui_section "Configuring Inference Network & NAT Gateway"

ui_step "Setting static IP (10.42.0.1) on dedicated Ethernet link..."
if configure_static_ip; then
  ui_success "Static IP 10.42.0.1 configured"
else
  ui_warning "Ethernet interface not ready — skipping static IP configuration for now"
fi

ui_step "Enabling IP forwarding (sysctl net.inet.ip.forwarding=1)..."
enable_ip_forwarding
ui_success "IP forwarding enabled"

ui_step "Configuring macOS Packet Filter (PF) NAT rules for 10.42.0.0/24..."
if setup_pf_nat; then
  ui_success "NAT gateway enabled for inference PC"
else
  ui_warning "Active WAN interface not found — NAT setup deferred"
fi
