#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$ROOT/.env"
DASH_ENV="$ROOT/dashboard/.env"
COMPOSE_CMD=()

set_dash_env_value() {
  local key=$1
  local value=$2
  local escaped=${value//&/\\&}
  if grep -q -E "^${key}=" "$DASH_ENV" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=${escaped}|" "$DASH_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >> "$DASH_ENV"
  fi
}

get_dash_env_value() {
  local key=$1
  grep -m1 -E "^${key}=" "$DASH_ENV" 2>/dev/null | cut -d'=' -f2-
}

set_env_value() {
  local key=$1
  local value=$2
  local escaped=${value//&/\\&}
  if grep -q -E "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

generate_password_secret() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits + "@%+=_-"
print("".join(secrets.choice(alphabet) for _ in range(24)))
PY
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9@%+=_-' | head -c24
    printf '\n'
    return
  fi
  echo "python3 or openssl is required to generate a password." >&2
  exit 1
}

generate_app_build_id() {
  date -u '+%Y%m%d%H%M%S'
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
  elif docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
  else
    echo "Docker Compose is required to restart the dashboard." >&2
    exit 1
  fi
}

main() {
  if [ ! -f "$DASH_ENV" ]; then
    echo "Missing $DASH_ENV. Run ./deploy.sh once before resetting dashboard credentials." >&2
    exit 1
  fi

  local username=${1:-}
  local password=${2:-}

  if [ -z "$username" ]; then
    username=$(get_dash_env_value DASHBOARD_SUPERADMIN_USERNAME)
    username=${username:-superadmin}
  fi

  if [ -z "$password" ]; then
    password=$(generate_password_secret)
  fi

  set_dash_env_value DASHBOARD_SUPERADMIN_USERNAME "$username"
  set_dash_env_value DASHBOARD_SUPERADMIN_PASSWORD "$password"
  set_dash_env_value APP_BUILD_ID "$(generate_app_build_id)"
  if [ -f "$ENV_FILE" ]; then
    set_env_value DASHBOARD_SUPERADMIN_USERNAME "$username"
    set_env_value DASHBOARD_SUPERADMIN_PASSWORD "$password"
  fi

  detect_compose_command
  (cd "$ROOT" && "${COMPOSE_CMD[@]}" -f docker-compose.yml up -d --build dashboard)

  cat <<MSG
Superadmin credentials updated locally in dashboard/.env
Username: $username
Password: $password

The dashboard container has been rebuilt and restarted.
MSG
}

main "$@"
