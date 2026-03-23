#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$ROOT/.env"
OUTPUT_FILE="$ROOT/mysql-init/99-runtime-reconcile.sql"

get_env_value() {
  local key=$1
  grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-
}

sql_escape() {
  local value=${1:-}
  value=${value//\\/\\\\}
  value=${value//\'/\'\'}
  printf '%s' "$value"
}

require_simple_identifier() {
  local label=$1
  local value=$2
  if [[ ! "$value" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "$label must use only letters, numbers, and underscores." >&2
    exit 1
  fi
}

main() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE. Run deploy.sh first." >&2
    exit 1
  fi

  local mysql_database mysql_user mysql_password mysql_read_user mysql_read_password
  mysql_database=$(get_env_value MYSQL_DATABASE)
  mysql_user=$(get_env_value MYSQL_USER)
  mysql_password=$(get_env_value MYSQL_PASSWORD)
  mysql_read_user=$(get_env_value MYSQL_READ_USER)
  mysql_read_password=$(get_env_value MYSQL_READ_PASSWORD)

  if [ -z "$mysql_database" ] || [ -z "$mysql_user" ] || [ -z "$mysql_password" ] || [ -z "$mysql_read_user" ] || [ -z "$mysql_read_password" ]; then
    echo "MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD, MYSQL_READ_USER, and MYSQL_READ_PASSWORD must be set in $ENV_FILE." >&2
    exit 1
  fi

  require_simple_identifier MYSQL_DATABASE "$mysql_database"
  require_simple_identifier MYSQL_USER "$mysql_user"
  require_simple_identifier MYSQL_READ_USER "$mysql_read_user"

  cat > "$OUTPUT_FILE" <<SQL
SET SQL_LOG_BIN=0;
CREATE DATABASE IF NOT EXISTS \`${mysql_database}\`;
CREATE USER IF NOT EXISTS '${mysql_user}'@'%' IDENTIFIED BY '$(sql_escape "$mysql_password")';
ALTER USER '${mysql_user}'@'%' IDENTIFIED BY '$(sql_escape "$mysql_password")';
GRANT ALL PRIVILEGES ON \`${mysql_database}\`.* TO '${mysql_user}'@'%' REQUIRE SSL;
CREATE USER IF NOT EXISTS '${mysql_read_user}'@'%' IDENTIFIED BY '$(sql_escape "$mysql_read_password")';
ALTER USER '${mysql_read_user}'@'%' IDENTIFIED BY '$(sql_escape "$mysql_read_password")';
GRANT SELECT ON \`${mysql_database}\`.* TO '${mysql_read_user}'@'%' REQUIRE SSL;
FLUSH PRIVILEGES;
SQL
}

main "$@"
