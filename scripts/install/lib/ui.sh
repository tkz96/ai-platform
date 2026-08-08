#!/usr/bin/env bash
# UI utilities for bootstrap.sh
# Provides colors, boxes, prompts, spinners, and status indicators.

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  RED='\033[31m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  BLUE='\033[34m'
  CYAN='\033[36m'
  WHITE='\033[37m'
  RESET='\033[0m'
else
  BOLD=''
  DIM=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  WHITE=''
  RESET=''
fi

# ── Symbols ─────────────────────────────────────────────────────────────────

SYM_OK="✓"
SYM_WARN="⚠"
SYM_FAIL="✗"
SYM_ARROW="→"

# ── Box Drawing ─────────────────────────────────────────────────────────────

BOX_WIDTH=60

ui_header() {
  local title="$1"
  local line
  line=$(printf '━%.0s' $(seq 1 $BOX_WIDTH))
  echo
  echo -e "${BOLD}${CYAN}${line}${RESET}"
  echo -e "${BOLD}${CYAN}  ${title}${RESET}"
  echo -e "${BOLD}${CYAN}${line}${RESET}"
  echo
}

ui_section() {
  local title="$1"
  echo
  echo -e "${BOLD}${WHITE}━━━ ${title} ━━━${RESET}"
  echo
}

# ── Status Messages ─────────────────────────────────────────────────────────

ui_success() {
  echo -e "  ${GREEN}${SYM_OK}${RESET} $1"
}

ui_warning() {
  echo -e "  ${YELLOW}${SYM_WARN}${RESET} $1"
}

ui_error() {
  echo -e "  ${RED}${SYM_FAIL}${RESET} $1"
}

ui_info() {
  echo -e "  ${BLUE}${SYM_ARROW}${RESET} $1"
}

ui_step() {
  echo -e "  ${CYAN}${SYM_ARROW}${RESET} $1"
}

ui_fatal() {
  echo -e "  ${RED}${BOLD}FATAL:${RESET} $1" >&2
  exit 1
}

# ── Prompts ─────────────────────────────────────────────────────────────────

ui_confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local answer

  if [[ "$default" == "Y" ]]; then
    printf "  ${BOLD}%s [Y/n]:${RESET} " "$prompt"
  else
    printf "  ${BOLD}%s [y/N]:${RESET} " "$prompt"
  fi

  read -r answer
  answer="${answer:-$default}"

  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

ui_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local i choice

  echo -e "  ${BOLD}${prompt}${RESET}"
  echo
  for i in "${!options[@]}"; do
    echo -e "    [$((i + 1))] ${options[$i]}"
  done
  echo
  printf "  ${BOLD}Choice:${RESET} "
  read -r choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
    echo "$choice"
    return 0
  fi

  return 1
}

ui_prompt_text() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  if [[ -n "$default" ]]; then
    printf "  ${BOLD}%s [%s]:${RESET} " "$prompt" "$default"
  else
    printf "  ${BOLD}%s:${RESET} " "$prompt"
  fi

  read -r answer
  echo "${answer:-$default}"
}

ui_prompt_secret() {
  local prompt="$1"
  local answer

  printf "  ${BOLD}%s:${RESET} " "$prompt"
  read -rs answer
  echo
  echo "$answer"
}

# ── System Info ─────────────────────────────────────────────────────────────

ui_system_info() {
  local macos_version arch memory disk

  macos_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  arch=$(uname -m)
  memory=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
  disk=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")

  echo -e "  ${DIM}Detected system:${RESET}"
  echo
  echo -e "    macOS        ${macos_version}"
  echo -e "    Architecture ${arch}"
  echo -e "    Memory       ${memory} GB"
  echo -e "    Disk         ${disk} GB free"
  echo
}

# ── Spinner ─────────────────────────────────────────────────────────────────

SPINNER_PID=""

ui_spinner_start() {
  local msg="$1"
  local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  printf "  ${CYAN}%s${RESET} " "${msg}"

  (
    while true; do
      local char="${chars:i%${#chars}:1}"
      printf "\r  ${CYAN}%s${RESET} %s" "$char" "$msg"
      sleep 0.1
      i=$(( (i + 1) % ${#chars} ))
    done
  ) &

  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

ui_spinner_stop() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r"
    # Clear the line
    printf '%*s\r' "$COLUMNS" ''
  fi
}

# ── Table ───────────────────────────────────────────────────────────────────

ui_table_row() {
  local col1="$1"
  local col2="$2"
  local col1_width="${3:-20}"

  printf "  %-${col1_width}s %s\n" "$col1" "$col2"
}

# ── Final Banner ────────────────────────────────────────────────────────────

ui_done_banner() {
  local domain="$1"
  local http_port="$2"
  local https_port="$3"
  local line
  line=$(printf '━%.0s' $(seq 1 $BOX_WIDTH))

  echo
  echo -e "${BOLD}${GREEN}${line}${RESET}"
  echo -e "${BOLD}${GREEN}  AI Platform is ready${RESET}"
  echo -e "${BOLD}${GREEN}${line}${RESET}"
  echo
  echo -e "  ${BOLD}Langfuse:${RESET}"
  echo -e "    http://localhost:3000"
  echo
  echo -e "  ${BOLD}LiteLLM:${RESET}"
  echo -e "    http://localhost:4000"
  echo
  echo -e "  ${BOLD}Caddy:${RESET}"
  echo -e "    http://localhost:${http_port}"
  echo -e "    https://localhost:${https_port}"
  echo
  echo -e "  ${BOLD}Platform:${RESET}"
  echo -e "    ${GREEN}${SYM_OK}${RESET} Healthy"
  echo
  echo -e "  ${BOLD}Inference:${RESET}"
  echo -e "    ${GREEN}${SYM_OK}${RESET} Connected"
  echo
  echo -e "${BOLD}${GREEN}${line}${RESET}"
  echo
}