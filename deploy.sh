#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$ROOT/.env"
ENV_EXAMPLE="$ROOT/.env.example"
DASH_ENV="$ROOT/dashboard/.env"
DASH_ENV_EX="$ROOT/dashboard/.env.example"
UPDATED_PKGS=0
PKG_MANAGER=""
COMPOSE_CMD=()

if [ "$(id -u)" -ne 0 ]; then
  echo "deploy.sh must be run with root privileges (sudo) so it can install packages and configure nginx." >&2
  exit 1
fi

trim() {
  local var="$*"
  var="${var#${var%%[![:space:]]*}}"
  var="${var%${var##*[![:space:]]}}"
  printf '%s' "$var"
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo "Created $ENV_FILE from the template. Review secrets before proceeding."
  fi
}

get_env_value() {
  local key=$1
  if [ ! -f "$ENV_FILE" ]; then
    return
  fi
  local value
  value=$(grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
  printf '%s' "$value"
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

get_dash_env_value() {
  local key=$1
  if [ ! -f "$DASH_ENV" ]; then
    return
  fi
  local value
  value=$(grep -m1 -E "^${key}=" "$DASH_ENV" 2>/dev/null | cut -d'=' -f2-)
  printf '%s' "$value"
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

append_allowed_origin() {
  local origin="https://$1"
  local current
  current=$(get_dash_env_value ALLOWED_ORIGINS)
  if [ -z "$current" ]; then
    set_dash_env_value ALLOWED_ORIGINS "$origin"
    return
  fi
  IFS=',' read -ra entries <<< "$current"
  for entry in "${entries[@]}"; do
    local trimmed
    trimmed=$(trim "$entry")
    if [ "$trimmed" = "$origin" ]; then
      return
    fi
  done
  set_dash_env_value ALLOWED_ORIGINS "$current,$origin"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    echo "Unsupported package manager. Install nginx and certbot manually." >&2
    PKG_MANAGER=""
  fi
}

ensure_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker" "compose")
  elif docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("docker-compose")
  else
    echo "Docker Compose is not installed. Install Docker Compose before running deploy.sh." >&2
    exit 1
  fi
}

install_packages() {
  local packages=("$@")
  if [ -z "$PKG_MANAGER" ]; then
    echo "No package manager detected; skip installing: ${packages[*]}." >&2
    return
  fi
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    if [ "$UPDATED_PKGS" -eq 0 ]; then
      apt-get update
      UPDATED_PKGS=1
    fi
    apt-get install -y "${packages[@]}"
  else
    ${PKG_MANAGER} install -y "${packages[@]}"
  fi
}

port_in_use() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | grep -E ":$port\$" >/dev/null 2>&1; then
      return 0
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln | awk '{print $4}' | grep -E ":$port\$" >/dev/null 2>&1; then
      return 0
    fi
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

find_available_port() {
  local start_port=$1
  local max_port=${2:-65535}
  local port=$start_port
  while [ "$port" -le "$max_port" ]; do
    if ! port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

configure_nginx_site() {
  local domain=$1
  local dashboard_port=${2:-8443}
  local sites_available="/etc/nginx/sites-available"
  local sites_enabled="/etc/nginx/sites-enabled"
  local symlink=false

  if [ ! -d "$sites_available" ]; then
    sites_available="/etc/nginx/conf.d"
    sites_enabled="$sites_available"
  fi

  mkdir -p "$sites_available" "$sites_enabled"
  local conf_path="$sites_available/database-manager.conf"
  cat <<NGINX > "$conf_path"
server {
  listen 80;
  server_name ${domain};

  location /.well-known/acme-challenge/ {
    root /var/www/html;
  }

  location / {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass https://127.0.0.1:${dashboard_port};
    proxy_ssl_verify off;
  }
}
NGINX

  if [ "$sites_available" != "$sites_enabled" ]; then
    ln -sf "$conf_path" "$sites_enabled/database-manager.conf"
    symlink=true
  fi

  if [ -e "$sites_enabled/default" ]; then
    rm -f "$sites_enabled/default"
  fi

  nginx -t
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx
  else
    nginx -s reload
  fi
}

obtain_ssl_certificate() {
  local domain=$1
  local email=$2
  if [ -d "/etc/letsencrypt/live/$domain" ]; then
    echo "Certificate for $domain already exists. Skipping certbot issuance."
    return
  fi
  certbot --nginx --redirect --agree-tos --noninteractive --email "$email" -d "$domain"
}

main() {
  ensure_env_file
  if [ ! -f "$DASH_ENV" ]; then
    cp "$DASH_ENV_EX" "$DASH_ENV"
    echo "Created dashboard/.env from template. Update SESSION_SECRET and verify SSL paths."
  fi

  local domain
  domain=$(trim "$(get_env_value DOMAIN)")
  if [ -z "$domain" ]; then
    read -rp "Enter the public domain that will host the dashboard (e.g. db.example.com): " domain
    domain=$(trim "$domain")
    if [ -z "$domain" ]; then
      echo "A domain is required for certificate provisioning." >&2
      exit 1
    fi
    set_env_value DOMAIN "$domain"
  fi

  local cert_email
  cert_email=$(trim "$(get_env_value CERT_EMAIL)")
  if [ -z "$cert_email" ]; then
    cert_email="admin@$domain"
    set_env_value CERT_EMAIL "$cert_email"
  fi

  append_allowed_origin "$domain"
  set_dash_env_value SKIP_INTERNAL_TLS true

  local session_secret
  session_secret=$(trim "$(get_dash_env_value SESSION_SECRET)")
  if [ -z "$session_secret" ] || [ "$session_secret" = "replace-with-strong-random" ]; then
    echo "WARNING: dashboard/.env contains the placeholder SESSION_SECRET. Replace it with a long random value before going to production."
  fi

  local mysql_port_pref
  mysql_port_pref=$(trim "$(get_env_value MYSQL_PORT)")
  mysql_port_pref=${mysql_port_pref:-3306}
  local mysql_port
  if ! mysql_port=$(find_available_port "$mysql_port_pref" 100); then
    echo "Unable to find a free port for MySQL starting at $mysql_port_pref. Please free some ports and re-run deploy.sh." >&2
    exit 1
  fi
  set_env_value MYSQL_PORT "$mysql_port"
  if [ "$mysql_port" != "$mysql_port_pref" ]; then
    echo "MySQL port $mysql_port_pref was in use; switching to $mysql_port."
  else
    echo "Using MySQL port $mysql_port."
  fi

  local dashboard_port_pref
  dashboard_port_pref=$(trim "$(get_env_value DASHBOARD_PORT)")
  dashboard_port_pref=${dashboard_port_pref:-8443}
  local dashboard_port
  if ! dashboard_port=$(find_available_port "$dashboard_port_pref" 100); then
    echo "Unable to find a free port for the dashboard starting at $dashboard_port_pref. Please free some ports and re-run deploy.sh." >&2
    exit 1
  fi
  set_env_value DASHBOARD_PORT "$dashboard_port"
  if [ "$dashboard_port" != "$dashboard_port_pref" ]; then
    echo "Dashboard port $dashboard_port_pref was in use; switching to $dashboard_port."
  else
    echo "Using dashboard port $dashboard_port."
  fi

  detect_package_manager
  if [ -z "$PKG_MANAGER" ] && ! command -v nginx >/dev/null 2>&1; then
    echo "No automatic package manager detected. Install nginx manually before running deploy.sh." >&2
    exit 1
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    install_packages nginx
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable nginx >/dev/null 2>&1 || true
    fi
  else
    echo "nginx already installed, skipping package install."
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx is still unavailable; please install it manually and re-run deploy.sh." >&2
    exit 1
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    install_packages certbot python3-certbot-nginx
  else
    echo "certbot already installed."
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    echo "certbot is still unavailable; please install it manually before running deploy.sh." >&2
    exit 1
  fi

  configure_nginx_site "$domain" "$dashboard_port"
  obtain_ssl_certificate "$domain" "$cert_email"

  ensure_compose_command
  echo "Generating internal TLS certs for MySQL and the dashboard..."
  "$ROOT/scripts/generate-certs.sh"

  echo "Bringing up docker compose stack..."
  "${COMPOSE_CMD[@]}" -f "$ROOT/docker-compose.yml" up -d --build

  echo "Deployment complete. Dashboard should be available over HTTPS at https://$domain." 
  echo "Make sure the firewall allows ports 80 and 443 and keep $ENV_FILE and dashboard/.env out of source control."
}

main "$@"
