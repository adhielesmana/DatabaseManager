#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$ROOT/.env"
COMPOSE_CMD=()

if [ ! -f "$ENV_FILE" ]; then
  echo "Please run deploy.sh once to create $ENV_FILE before using intelligent-deploy.sh." >&2
  exit 1
fi

get_domain() {
  grep -m1 -E '^DOMAIN=' "$ENV_FILE" | cut -d'=' -f2-
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

main() {
  local domain
  domain=$(get_domain)
  if [ -z "$domain" ]; then
    echo "DOMAIN is missing from $ENV_FILE. Please set it manually or re-run deploy.sh." >&2
    exit 1
  fi

  detect_compose_command
  echo "Pulling container updates..."
  (cd "$ROOT" && "${COMPOSE_CMD[@]}" pull --parallel)
  echo "Rebuilding and restarting the stack..."
  (cd "$ROOT" && "${COMPOSE_CMD[@]}" -f docker-compose.yml up -d --build)
  echo "Update complete; dashboard should stay available at https://$domain."
}

main "$@"
