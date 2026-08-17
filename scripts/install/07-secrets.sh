#!/usr/bin/env bash
# Phase 7: Generate secrets and create .env
# Interactively generates or prompts for all required secrets.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
SECRETS_DIR="$PROJECT_ROOT/secrets"

ui_section "Secrets Configuration"

# Create secrets directories
mkdir -p "$SECRETS_DIR/ssh"
chmod 700 "$SECRETS_DIR/ssh"

# Ensure cluster orchestrator SSH keypair exists
if [[ ! -f "$SECRETS_DIR/ssh/cluster_orchestrator_key" ]]; then
  ssh-keygen -t ed25519 -f "$SECRETS_DIR/ssh/cluster_orchestrator_key" -N "" -C "ai-platform-orchestrator" >/dev/null 2>&1
  chmod 600 "$SECRETS_DIR/ssh/cluster_orchestrator_key"
  chmod 644 "$SECRETS_DIR/ssh/cluster_orchestrator_key.pub"
  ui_success "Cluster Orchestrator SSH keypair generated"
else
  ui_success "Cluster Orchestrator SSH keypair already exists"
fi

# Ensure enrollment session token exists
if [[ ! -f "$SECRETS_DIR/enrollment_token" ]]; then
  TOKEN="sk-enroll-$(openssl rand -hex 16 2>/dev/null)"
  echo "$TOKEN" > "$SECRETS_DIR/enrollment_token"
  chmod 600 "$SECRETS_DIR/enrollment_token"
  ui_success "Enrollment session token generated"
else
  ui_success "Enrollment session token already exists"
fi

# ── Helper Functions ────────────────────────────────────────────────────────

generate_secret() {
  # Generate a random secret of specified length
  local length="${1:-32}"
  openssl rand -base64 "$length" 2>/dev/null | tr -d '\n' | tr -d '=+/' | head -c "$length"
}

generate_key() {
  # Generate a key with a prefix (e.g., sk-)
  local prefix="$1"
  local length="${2:-32}"
  echo "${prefix}$(generate_secret "$length")"
}

generate_hex_secret() {
  local length="${1:-64}"
  openssl rand -hex $((length / 2)) 2>/dev/null | tr -d '\n'
}

secret_exists() {
  local file="$1"
  [[ -f "$file" ]] && [[ -s "$file" ]]
}

get_or_generate() {
  # Get existing secret, or generate/prompt for new one
  local name="$1"
  local file="$2"
  local prompt="$3"
  local prefix="${4:-}"

  if secret_exists "$file"; then
    ui_success "$name: already configured" >&2
    cat "$file"
    return 0
  fi

  if ui_confirm "Generate $prompt automatically?"; then
    local value
    if [[ "$name" == *"encryption key"* ]]; then
      value=$(generate_hex_secret 64)
    else
      value=$(generate_key "$prefix" 32)
    fi
    echo "$value" > "$file"
    chmod 600 "$file"
    ui_success "$name: generated" >&2
    echo "$value"
    return 0
  fi

  local manual
  manual=$(ui_prompt_secret "Enter $prompt")
  if [[ -z "$manual" ]]; then
    ui_error "$name: value cannot be empty" >&2
    return 1
  fi
  echo "$manual" > "$file"
  chmod 600 "$file"
  ui_success "$name: saved" >&2
  echo "$manual"
  return 0
}

# ── PostgreSQL ──────────────────────────────────────────────────────────────

ui_section "PostgreSQL"

postgres_password=$(get_or_generate \
  "PostgreSQL password" \
  "$SECRETS_DIR/postgres_password" \
  "a secure PostgreSQL password")

# ── ClickHouse ─────────────────────────────────────────────────────────────

ui_section "ClickHouse"

clickhouse_password=$(get_or_generate \
  "ClickHouse password" \
  "$SECRETS_DIR/clickhouse_password" \
  "a secure ClickHouse password")

# ── LiteLLM ────────────────────────────────────────────────────────────────

ui_section "LiteLLM"

litellm_master_key=$(get_or_generate \
  "LiteLLM master key" \
  "$SECRETS_DIR/litellm_master_key" \
  "a LiteLLM master key" \
  "sk-litellm-")

# ── Langfuse ───────────────────────────────────────────────────────────────

ui_section "Langfuse"

langfuse_secret_key=$(get_or_generate \
  "Langfuse secret key" \
  "$SECRETS_DIR/langfuse_secret_key" \
  "a Langfuse secret key" \
  "sk-langfuse-")

langfuse_salt=$(get_or_generate \
  "Langfuse salt" \
  "$SECRETS_DIR/langfuse_salt" \
  "a Langfuse salt")

langfuse_encryption_key=$(get_or_generate \
  "Langfuse encryption key" \
  "$SECRETS_DIR/langfuse_encryption_key" \
  "a 64-character Langfuse encryption key")

nextauth_secret=$(get_or_generate \
  "NextAuth secret" \
  "$SECRETS_DIR/nextauth_secret" \
  "a NextAuth secret")

# Read existing inference settings if .env already exists
inference_host="10.42.0.2"
inference_bind_host="10.42.0.2"
inference_port="8080"
inference_health_endpoint="/health"
inference_protocol="http"
inference_service_user="ubuntu"
inference_working_directory="/home/ubuntu"
inference_binary_path="/usr/local/bin/llama-server"
inference_model_path="/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf"
platform_domain="ai.xynotech.internal"

if [[ -f "$ENV_FILE" ]]; then
  inference_host=$(grep '^INFERENCE_HOST=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "10.42.0.2")
  inference_bind_host=$(grep '^INFERENCE_BIND_HOST=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "10.42.0.2")
  inference_port=$(grep '^INFERENCE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "8080")
  inference_health_endpoint=$(grep '^INFERENCE_HEALTH_ENDPOINT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "/health")
  inference_protocol=$(grep '^INFERENCE_PROTOCOL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "http")
  inference_service_user=$(grep '^INFERENCE_SERVICE_USER=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "ubuntu")
  inference_working_directory=$(grep '^INFERENCE_WORKING_DIRECTORY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "/home/ubuntu")
  inference_binary_path=$(grep '^INFERENCE_BINARY_PATH=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "/usr/local/bin/llama-server")
  inference_model_path=$(grep '^INFERENCE_MODEL_PATH=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf")
  platform_domain=$(grep '^PLATFORM_DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "ai.xynotech.internal")
  [[ -z "$inference_host" ]] && inference_host="10.42.0.2"
  [[ -z "$inference_bind_host" ]] && inference_bind_host="10.42.0.2"
  [[ -z "$inference_port" ]] && inference_port="8080"
  [[ -z "$inference_health_endpoint" ]] && inference_health_endpoint="/health"
  [[ -z "$inference_protocol" ]] && inference_protocol="http"
  [[ -z "$inference_service_user" ]] && inference_service_user="ubuntu"
  [[ -z "$inference_working_directory" ]] && inference_working_directory="/home/ubuntu"
  [[ -z "$inference_binary_path" ]] && inference_binary_path="/usr/local/bin/llama-server"
  [[ -z "$inference_model_path" ]] && inference_model_path="/home/ubuntu/AI/Models/GGUF/Qwen/Qwen3.6-35B-A3B-UD-Q5_K_S.gguf"
  [[ -z "$platform_domain" ]] && platform_domain="ai.xynotech.internal"
fi

# ── Write .env ─────────────────────────────────────────────────────────────

ui_section "Writing .env"

cat > "$ENV_FILE" <<EOF
# GENERATED BY bootstrap.sh — DO NOT EDIT
# Edit files in secrets/ and re-run ./bootstrap.sh render

# PostgreSQL
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=platform_db

# LiteLLM
LITELLM_MASTER_KEY=${litellm_master_key}
LITELLM_DATABASE_URL=postgresql://postgres:${postgres_password}@postgres:5432/platform_db

# Langfuse
DATABASE_URL=postgresql://postgres:${postgres_password}@postgres:5432/platform_db
LANGFUSE_SECRET_KEY=${langfuse_secret_key}
LANGFUSE_SALT=${langfuse_salt}
SALT=${langfuse_salt}
ENCRYPTION_KEY=${langfuse_encryption_key}
NEXTAUTH_SECRET=${nextauth_secret}
NEXTAUTH_URL=http://localhost:3000
LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse
CLICKHOUSE_URL=http://clickhouse:8123
CLICKHOUSE_MIGRATION_URL=clickhouse://clickhouse:9000
CLICKHOUSE_CLUSTER_ENABLED=false
REDIS_HOST=redis
REDIS_PORT=6379

# ClickHouse
CLICKHOUSE_USER=clickhouse
CLICKHOUSE_PASSWORD=${clickhouse_password}

# Platform & Inference Settings
INFERENCE_HOST=${inference_host}
INFERENCE_BIND_HOST=${inference_bind_host}
INFERENCE_PORT=${inference_port}
INFERENCE_HEALTH_ENDPOINT=${inference_health_endpoint}
INFERENCE_PROTOCOL=${inference_protocol}
INFERENCE_SERVICE_USER=${inference_service_user}
INFERENCE_WORKING_DIRECTORY=${inference_working_directory}
INFERENCE_BINARY_PATH=${inference_binary_path}
INFERENCE_MODEL_PATH=${inference_model_path}
PLATFORM_DOMAIN=${platform_domain}
EOF

chmod 600 "$ENV_FILE"
ui_success ".env written with all secrets"