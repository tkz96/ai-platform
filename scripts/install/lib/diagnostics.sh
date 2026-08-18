#!/usr/bin/env bash
# lib/diagnostics.sh — Structured diagnostic helper functions for installer
# Formats and redacts operational failure diagnostics for terminal display and logs.

set -euo pipefail

redact_sensitive_text() {
  local text="$1"
  if [[ -z "$text" ]]; then
    echo ""
    return 0
  fi

  echo "$text" | sed -E \
    -e 's/sk-[a-zA-Z0-9_-]{12,}/[REDACTED_TOKEN]/g' \
    -e 's/(POSTGRES_PASSWORD|CLICKHOUSE_PASSWORD|NEXTAUTH_SECRET|ENCRYPTION_KEY|LITELLM_MASTER_KEY)=[^ ]+/\1=[REDACTED]/g' \
    -e 's/(password|secret|key|token)=[^ ]+/\1=[REDACTED]/gI'
}

render_diagnostic_box() {
  local operation="$1"
  local cmd="$2"
  local exit_code="$3"
  local stderr_raw="$4"
  local state_info="$5"
  local recommendation="$6"

  local clean_cmd
  clean_cmd=$(redact_sensitive_text "$cmd")
  local clean_stderr
  clean_stderr=$(redact_sensitive_text "$stderr_raw")
  local clean_recommendation
  clean_recommendation=$(redact_sensitive_text "$recommendation")

  echo
  echo -e "  \033[31m\033[1m━━━ Diagnostic Report: ${operation} ━━━\033[0m"
  if [[ -n "$clean_cmd" ]]; then
    echo -e "  \033[1mCommand Executed:\033[0m ${clean_cmd}"
  fi
  echo -e "  \033[1mExit Code:\033[0m        ${exit_code}"

  if [[ -n "$clean_stderr" ]]; then
    echo -e "  \033[1mCaptured Error:\033[0m"
    echo "$clean_stderr" | sed 's/^/    /'
  fi

  if [[ -n "$state_info" ]]; then
    echo -e "  \033[1mDetected State:\033[0m"
    echo "$state_info" | sed 's/^/    /'
  fi

  if [[ -n "$clean_recommendation" ]]; then
    echo
    echo -e "  \033[1mRecommended Action:\033[0m"
    echo -e "  ${clean_recommendation}"
  fi
  echo
}
