#!/usr/bin/env bash
# Phase 0: Check macOS prerequisites
# Verifies macOS version, architecture, and system requirements.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

ui_section "Checking macOS"

# Check macOS version
macos_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
macos_major=$(echo "$macos_version" | cut -d. -f1)

if [[ "$macos_major" -ge 14 ]]; then
  ui_success "macOS $macos_version (>= 14)"
else
  ui_quit_prompt "macOS $macos_version detected. Requires macOS 14 or later." "Upgrade macOS to version 14 or later and re-run ./bootstrap.sh"
fi

# Check architecture
arch=$(uname -m)
if [[ "$arch" == "arm64" ]]; then
  ui_success "Architecture: $arch (Apple Silicon)"
else
  ui_warning "Architecture: $arch (Intel). Podman may have limited support."
fi

# Check disk space
while true; do
  disk_free=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
  if (( disk_free >= 60 )); then
    ui_success "Disk space: ${disk_free} GB free (>= 60 GB)"
    break
  else
    ui_recoverable "Disk space: ${disk_free} GB free. Requires at least 60 GB." "Free up disk space on this volume, then press Enter to re-check."
  fi
done

# Check memory
memory_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
if (( memory_gb >= 8 )); then
  ui_success "Memory: ${memory_gb} GB (>= 8 GB)"
else
  ui_warning "Memory: ${memory_gb} GB. Recommended at least 8 GB."
fi

# Check Command Line Tools
while true; do
  if xcode-select -p >/dev/null 2>&1; then
    ui_success "Xcode Command Line Tools installed"
    break
  else
    ui_step "Installing Xcode Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    ui_recoverable "Xcode Command Line Tools installation required." "Complete the GUI installation dialog, then press Enter to re-check."
  fi
done

ui_success "macOS prerequisites satisfied"