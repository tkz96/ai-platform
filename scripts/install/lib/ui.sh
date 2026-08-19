#!/usr/bin/env bash
# UI utilities for bootstrap.sh
# Provides colors, boxes, prompts, spinners, ASCII art, and status indicators.

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
  MAGENTA='\033[35m'
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
  MAGENTA=''
  RESET=''
fi

# ── Symbols ─────────────────────────────────────────────────────────────────

SYM_OK="✓"
SYM_WARN="⚠"
SYM_FAIL="✗"
SYM_ARROW="→"
SYM_DOT="•"

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

# ── ASCII Art Splash ────────────────────────────────────────────────────────

ui_splash() {
  local line
  line=$(printf '━%.0s' $(seq 1 $BOX_WIDTH))

  echo
  echo -e "${BOLD}${CYAN}${line}${RESET}"
  echo
  echo -e "${BOLD}${MAGENTA}"
  echo -e "   ██╗  ██╗██╗   ██╗███╗   ██╗ ██████╗"
  echo -e "   ╚██╗██╔╝╚██╗ ██╔╝████╗  ██║██╔═══██╗"
  echo -e "    ╚███╔╝  ╚████╔╝ ██╔██╗ ██║██║   ██║"
  echo -e "    ██╔██╗   ╚██╔╝  ██║╚██╗██║██║   ██║"
  echo -e "   ██╔╝ ██╗   ██║   ██║ ╚████║╚██████╔╝"
  echo -e "   ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝"
  echo -e "${RESET}"
  echo -e "${BOLD}${CYAN}  AI Platform — Self-Hosted AI Infrastructure${RESET}"
  echo -e "${BOLD}${CYAN}${line}${RESET}"
  echo
  echo -e "  ${DIM}Version: 0.1.0${RESET}"
  echo -e "  ${DIM}Repository: github.com/tkz96/ai-platform${RESET}"
  echo
}

ui_system_info() {
  local os_ver arch mem_gb disk_free
  os_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  arch=$(uname -m)
  mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
  disk_free=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")

  echo -e "  ${BOLD}System Information${RESET}"
  echo
  echo -e "    ${DIM}macOS${RESET}        ${os_ver}"
  echo -e "    ${DIM}Architecture${RESET} ${arch}"
  echo -e "    ${DIM}Memory${RESET}       ${mem_gb} GB"
  echo -e "    ${DIM}Disk${RESET}         ${disk_free} GB free"
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

is_noninteractive() {
  [[ "${NONINTERACTIVE:-0}" == "1" ]] || ! [[ -t 0 ]]
}

ui_recoverable() {
  local error_msg="$1"
  local guidance="$2"

  echo
  echo -e "  ${RED}${BOLD}━━━ Problem Detected ━━━${RESET}"
  echo -e "  ${RED}${SYM_FAIL}${RESET} ${error_msg}"
  echo
  echo -e "  ${BOLD}How to fix:${RESET}"
  echo -e "  ${guidance}"
  echo

  if is_noninteractive; then
    ui_warning "Non-interactive execution mode: skipping retry prompt."
    return 1
  fi

  echo -e "  ${DIM}Press Enter to retry  |  Press Q to quit${RESET}"

  while true; do
    local key=""
    read -rsn1 key
    case "$key" in
      q|Q)
        echo
        ui_info "Exiting at user request."
        return 1
        ;;
      "")  # Enter key
        return 0
        ;;
    esac
  done
}

ui_quit_prompt() {
  local error_msg="$1"
  local guidance="${2:-}"

  echo
  echo -e "  ${RED}${BOLD}━━━ Cannot Continue ━━━${RESET}"
  echo -e "  ${RED}${SYM_FAIL}${RESET} ${error_msg}"
  if [[ -n "$guidance" ]]; then
    echo
    echo -e "  ${BOLD}What you can do:${RESET}"
    echo -e "  ${guidance}"
  fi
  echo
  echo -e "  ${DIM}Exiting installer...${RESET}"
  exit 1
}

ui_recovery_menu() {
  local title="$1"
  local error_msg="$2"
  shift 2
  local options=("$@")

  echo >&2
  echo -e "  ${RED}${BOLD}━━━ Recovery Required: ${title} ━━━${RESET}" >&2
  echo -e "  ${RED}${SYM_FAIL}${RESET} ${error_msg}" >&2
  echo >&2
  echo -e "  ${BOLD}Select a recovery action to continue without exiting:${RESET}" >&2
  echo >&2
  local i
  for i in "${!options[@]}"; do
    echo -e "    ${CYAN}[$((i + 1))]${RESET} ${options[$i]}" >&2
  done
  echo >&2

  if is_noninteractive; then
    ui_info "Non-interactive mode: selecting default recovery action (option 1: ${options[0]:-default})." >&2
    echo "0"
    return 0
  fi

  while true; do
    printf "  ${BOLD}Select option (1-%d):${RESET} " "${#options[@]}" >&2
    local choice
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "$((choice - 1))"
      return 0
    fi
    ui_warning "Invalid choice. Please enter 1-${#options[@]}." >&2
  done
}


_UI_LIVE_LINES=0

ui_live_status() {
  local line_count=$#
  if [[ "${_UI_LIVE_LINES:-0}" -gt 0 ]]; then
    printf '\033[%dA' "$_UI_LIVE_LINES"
  fi
  _UI_LIVE_LINES=$line_count
  for line in "$@"; do
    printf '\033[2K\r%b\n' "$line"
  done
}

ui_live_status_clear() {
  if [[ "${_UI_LIVE_LINES:-0}" -gt 0 ]]; then
    printf '\033[%dA' "$_UI_LIVE_LINES"
    for (( i=0; i<_UI_LIVE_LINES; i++ )); do
      printf '\033[2K\r\n'
    done
    printf '\033[%dA' "$_UI_LIVE_LINES"
  fi
  _UI_LIVE_LINES=0
}

ui_fatal() {
  ui_quit_prompt "$1" "You can fix the issue and re-run: ./bootstrap.sh"
}

# ── Prompts ─────────────────────────────────────────────────────────────────

ui_confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local answer

  if is_noninteractive; then
    case "$default" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      *) return 1 ;;
    esac
  fi

  echo >&2
  if [[ "$default" == "Y" ]]; then
    printf "  ${BOLD}%s [Y/n]:${RESET} " "$prompt" >&2
  else
    printf "  ${BOLD}%s [y/N]:${RESET} " "$prompt" >&2
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

  echo >&2
  echo -e "  ${BOLD}${prompt}${RESET}" >&2
  echo >&2
  for i in "${!options[@]}"; do
    echo -e "    ${CYAN}[$((i + 1))]${RESET} ${options[$i]}" >&2
  done
  echo >&2

  if is_noninteractive; then
    ui_info "Non-interactive mode: selecting default choice (option 1: ${options[0]:-default})." >&2
    echo "0"
    return 0
  fi

  while true; do
    printf "  ${BOLD}Select an option (1-%d):${RESET} " "${#options[@]}" >&2
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "$((choice - 1))"
      return 0
    fi
    ui_warning "Invalid selection. Please enter a number between 1 and ${#options[@]}." >&2
  done
}

ui_prompt_text() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  if is_noninteractive; then
    echo "$default"
    return 0
  fi

  echo >&2
  if [[ -n "$default" ]]; then
    printf "  ${BOLD}%s [%s]:${RESET} " "$prompt" "$default" >&2
  else
    printf "  ${BOLD}%s:${RESET} " "$prompt" >&2
  fi

  read -r answer
  answer="${answer:-$default}"
  echo "$answer"
}

ui_prompt_secret() {
  local prompt="$1"
  local answer

  if is_noninteractive; then
    ui_error "Cannot prompt for secret in non-interactive mode." >&2
    return 1
  fi

  echo >&2
  printf "  ${BOLD}%s:${RESET} " "$prompt" >&2
  read -rs answer
  echo >&2
  echo "$answer"
}

ui_dependency_check() {
  local name="$1"
  local check_cmd="$2"
  local version_cmd="${3:-}"

  if eval "$check_cmd" >/dev/null 2>&1; then
    local ver=""
    if [[ -n "$version_cmd" ]]; then
      ver=$(eval "$version_cmd" 2>/dev/null || echo "")
    fi
    if [[ -n "$ver" ]]; then
      ui_success "$name ($ver)"
    else
      ui_success "$name"
    fi
    return 0
  else
    ui_error "$name (not found)"
    return 1
  fi
}

ui_done_banner() {
  local domain="${1:-localhost}"
  local http_port="${2:-8080}"
  local https_port="${3:-8443}"

  echo
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${GREEN}  AI Platform is ready${RESET}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
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
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo
}