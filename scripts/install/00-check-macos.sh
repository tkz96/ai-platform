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
  ui_error "macOS $macos_version detected. Requires macOS 14 or later."
  exit 1
fi

# Check architecture
arch=$(uname -m)
if [[ "$arch" == "arm64" ]]; then
  ui_success "Architecture: $arch (Apple Silicon)"
else
  ui_warning "Architecture: $arch (Intel). Podman may have limited support."
fi

# Check disk space
disk_free=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
if (( disk_free >= 60 )); then
  ui_success "Disk space: ${disk_free} GB free (>= 60 GB)"
else
  ui_error "Disk space: ${disk_free} GB free. Requires at least 60 GB."
  exit 1
fi

# Check memory
memory_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
if (( memory_gb >= 8 )); then
  ui_success "Memory: ${memory_gb} GB (>= 8 GB)"
else
  ui_warning "Memory: ${memory_gb} GB. Recommended at least 8 GB."
fi

# Check Command Line Tools
if xcode-select -p >/dev/null 2>&1; then
  ui_success "Xcode Command Line Tools installed"
else
  ui_step "Installing Xcode Command Line Tools..."
  xcode-select --install 2>/dev/null || true
  ui_warning "Please complete the Xcode Command Line Tools installation, then re-run ./bootstrap.sh"
  exit 1
fi

ui_success "macOS prerequisites satisfied"