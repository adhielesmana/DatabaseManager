#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$ROOT/.env"
DASH_ENV="$ROOT/dashboard/.env"
COMPOSE_CMD=()

if [ ! -f "$ENV_FILE" ]; then
  echo "Please run deploy.sh once to create $ENV_FILE before using intelligent-deploy.sh." >&2
  exit 1
fi

get_domain() {
  grep -m1 -E '^DOMAIN=' "$ENV_FILE" | cut -d'=' -f2-
}

get_env_value() {
  local key=$1
  grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-
}

get_dash_env_value() {
  local key=$1
  grep -m1 -E "^${key}=" "$DASH_ENV" 2>/dev/null | cut -d'=' -f2-
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
  elif docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
  else
    echo "Docker Compose is not installed. Install Docker Compose before running intelligent-deploy.sh." >&2
    exit 1
  fi
}

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

generate_app_build_id() {
  date -u '+%Y%m%d%H%M%S'
}

sync_private_dashboard_value() {
  local key=$1
  local root_value
  local dash_value
  root_value=$(get_env_value "$key")
  dash_value=$(get_dash_env_value "$key")

  if [ -n "$root_value" ] && [[ ! "$root_value" == replace-* ]]; then
    set_dash_env_value "$key" "$root_value"
    return
  fi

  if [ -n "$dash_value" ] && [[ ! "$dash_value" == replace-* ]]; then
    return
  fi

  echo "Missing private value for $key. Set it in $ENV_FILE or $DASH_ENV before running intelligent-deploy.sh." >&2
  exit 1
}

sync_dashboard_database_env() {
  set_dash_env_value DB_HOST "mysql"
  set_dash_env_value DB_PORT "3306"
  set_dash_env_value DB_USER "$(get_env_value MYSQL_USER)"
  set_dash_env_value DB_PASSWORD "$(get_env_value MYSQL_PASSWORD)"
  set_dash_env_value DB_NAME "$(get_env_value MYSQL_DATABASE)"
  sync_private_dashboard_value DASHBOARD_SUPERADMIN_USERNAME
  sync_private_dashboard_value DASHBOARD_SUPERADMIN_PASSWORD
  sync_private_dashboard_value DASHBOARD_ADMIN_USERNAME
  sync_private_dashboard_value DASHBOARD_ADMIN_PASSWORD
  sync_private_dashboard_value DASHBOARD_USER_USERNAME
  sync_private_dashboard_value DASHBOARD_USER_PASSWORD
}

main() {
  local domain
  domain=$(get_domain)
  if [ -z "$domain" ]; then
    echo "DOMAIN is missing from $ENV_FILE. Please set it manually or re-run deploy.sh." >&2
    exit 1
  fi
  if [ ! -f "$DASH_ENV" ]; then
    echo "Please run deploy.sh once to create $DASH_ENV before using intelligent-deploy.sh." >&2
    exit 1
  fi

  detect_compose_command
  sync_dashboard_database_env
  set_dash_env_value APP_BUILD_ID "$(generate_app_build_id)"
  echo "Pulling container updates..."
  (cd "$ROOT" && "${COMPOSE_CMD[@]}" pull --parallel)
  echo "Rebuilding and restarting the stack..."
  (cd "$ROOT" && "${COMPOSE_CMD[@]}" -f docker-compose.yml up -d --build)
  echo "Update complete; dashboard should stay available at https://$domain."
}

main "$@"
