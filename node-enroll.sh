#!/usr/bin/env bash
# AI Platform — Node Enrollment Wrapper
# Forwarding directly to scripts/inference/node-enroll.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/scripts/inference/node-enroll.sh" "$@"
