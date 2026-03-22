#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$ROOT/.env"
ENV_EXAMPLE="$ROOT/.env.example"
DASH_ENV="$ROOT/dashboard/.env"
DASH_ENV_EX="$ROOT/dashboard/.env.example"
DOCKER_COMPOSE_FILE="$ROOT/docker-compose.yml"
CERTBOT_WEBROOT="/var/www/certbot"
NGINX_SITE_NAME="database-manager.conf"
UPDATED_PKGS=0
PKG_MANAGER=""
COMPOSE_CMD=()
PYTHON_BIN=""
DEFAULT_SUPERADMIN_USERNAME_HASH='$2a$10$CGzDK83j4d6HeAUcy9rgSuxiDRdnoQlNgnLG0hbwmH1ZLy.dN291K'
DEFAULT_SUPERADMIN_PASSWORD_HASH='$2a$10$SeF19O8IzJMTOfZAIufoV.OPze9.ya6Ty1jFemMXlCTM9LZmmGWG.'

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

generate_session_secret() {
  if [ -n "$PYTHON_BIN" ] && "$PYTHON_BIN" - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
  then
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  head -c32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c64
}

generate_password_secret() {
  if [ -n "$PYTHON_BIN" ] && "$PYTHON_BIN" - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits + "@#%+=_-"
print("".join(secrets.choice(alphabet) for _ in range(24)))
PY
  then
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9@#%+=_-' | head -c24
    printf '\n'
    return
  fi
  head -c48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9@#%+=_-' | head -c24
  printf '\n'
}

generate_app_build_id() {
  date -u '+%Y%m%d%H%M%S'
}

secret_sha256() {
  local value=${1:-}
  if [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" - "$value" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl dgst -sha256 -r | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
    return
  fi
  return 1
}

is_placeholder_secret() {
  local value=${1:-}
  local value_hash=""
  case "$value" in
    ""|replace-*)
      return 0
      ;;
  esac
  value_hash=$(secret_sha256 "$value" 2>/dev/null || true)
  case "$value_hash" in
    a9c464c5c6db80df65e45846348ee982b2e6ac59d025383e5f1311211ef4cecb|69a0ef9a072fefc215d2037bff59c05151772ba7229b603623e72eeb0535885d|577b4f114c8df68245336a44e37f9cab29924eb066282e22991fad2a23ddf70c)
      return 0
      ;;
  esac
  return 1
}

ensure_session_secret() {
  local current
  current=$(trim "$(get_dash_env_value SESSION_SECRET)")
  if [ -z "$current" ] || [ "$current" = "replace-with-strong-secret" ]; then
    local secret
    secret=$(generate_session_secret)
    if [ -n "$secret" ]; then
      set_dash_env_value SESSION_SECRET "$secret"
      echo "Seeded dashboard SESSION_SECRET with a strong random value."
    fi
  fi
}

ensure_dashboard_user_value() {
  local key=$1
  local fallback=$2
  local current
  current=$(trim "$(get_dash_env_value "$key")")
  if [ -z "$current" ] || [[ "$current" == replace-* ]]; then
    set_dash_env_value "$key" "$fallback"
  fi
}

clear_dash_env_value() {
  local key=$1
  if grep -q -E "^${key}=" "$DASH_ENV" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=|" "$DASH_ENV"
  else
    printf '%s=\n' "$key" >> "$DASH_ENV"
  fi
}

apply_superadmin_plain_credentials() {
  local username=$1
  local password=$2
  set_env_value DASHBOARD_SUPERADMIN_USERNAME "$username"
  set_env_value DASHBOARD_SUPERADMIN_PASSWORD "$password"
  set_dash_env_value DASHBOARD_SUPERADMIN_USERNAME "$username"
  set_dash_env_value DASHBOARD_SUPERADMIN_PASSWORD "$password"
  clear_dash_env_value DASHBOARD_SUPERADMIN_USERNAME_HASH
  clear_dash_env_value DASHBOARD_SUPERADMIN_PASSWORD_HASH
}

apply_superadmin_hash_credentials() {
  local username_hash=$1
  local password_hash=$2
  set_dash_env_value DASHBOARD_SUPERADMIN_USERNAME "replace-superadmin-username"
  set_dash_env_value DASHBOARD_SUPERADMIN_PASSWORD "replace-superadmin-password"
  set_dash_env_value DASHBOARD_SUPERADMIN_USERNAME_HASH "$username_hash"
  set_dash_env_value DASHBOARD_SUPERADMIN_PASSWORD_HASH "$password_hash"
}

ensure_superadmin_credentials() {
  local root_username
  local root_password
  local root_username_hash
  local root_password_hash
  root_username=$(trim "$(get_env_value DASHBOARD_SUPERADMIN_USERNAME)")
  root_password=$(trim "$(get_env_value DASHBOARD_SUPERADMIN_PASSWORD)")
  root_username_hash=$(trim "$(get_env_value DASHBOARD_SUPERADMIN_USERNAME_HASH)")
  root_password_hash=$(trim "$(get_env_value DASHBOARD_SUPERADMIN_PASSWORD_HASH)")

  if [ -n "$root_username" ] && [ -n "$root_password" ] &&
    [[ ! "$root_username" == replace-* ]] && [[ ! "$root_password" == replace-* ]]; then
    apply_superadmin_plain_credentials "$root_username" "$root_password"
    return
  fi

  if [ -n "$root_username_hash" ] && [ -n "$root_password_hash" ] &&
    [[ ! "$root_username_hash" == replace-* ]] && [[ ! "$root_password_hash" == replace-* ]]; then
    apply_superadmin_hash_credentials "$root_username_hash" "$root_password_hash"
    return
  fi

  apply_superadmin_hash_credentials "$DEFAULT_SUPERADMIN_USERNAME_HASH" "$DEFAULT_SUPERADMIN_PASSWORD_HASH"
}

ensure_private_dashboard_value() {
  local key=$1
  local fallback=$2
  local root_value
  local dash_value
  root_value=$(trim "$(get_env_value "$key")")
  dash_value=$(trim "$(get_dash_env_value "$key")")

  if [ -n "$root_value" ] && [[ ! "$root_value" == replace-* ]]; then
    set_dash_env_value "$key" "$root_value"
    return
  fi

  if [ -n "$dash_value" ] && [[ ! "$dash_value" == replace-* ]]; then
    set_env_value "$key" "$dash_value"
    return
  fi

  set_env_value "$key" "$fallback"
  set_dash_env_value "$key" "$fallback"
}

ensure_dashboard_credentials() {
  ensure_superadmin_credentials
  ensure_private_dashboard_value DASHBOARD_ADMIN_USERNAME "admin"
  ensure_private_dashboard_value DASHBOARD_ADMIN_PASSWORD "$(generate_password_secret)"
  ensure_private_dashboard_value DASHBOARD_USER_USERNAME "user"
  ensure_private_dashboard_value DASHBOARD_USER_PASSWORD "$(generate_password_secret)"
}

ensure_mysql_secret() {
  local key=$1
  local fallback=$2
  local current
  current=$(trim "$(get_env_value "$key")")
  if is_placeholder_secret "$current"; then
    set_env_value "$key" "$fallback"
  fi
}

ensure_mysql_value() {
  local key=$1
  local fallback=$2
  local current
  current=$(trim "$(get_env_value "$key")")
  if [ -z "$current" ] || [[ "$current" == replace-* ]]; then
    set_env_value "$key" "$fallback"
  fi
}

sync_dashboard_database_env() {
  set_dash_env_value DB_HOST "mysql"
  set_dash_env_value DB_PORT "3306"
  set_dash_env_value DB_USER "$(trim "$(get_env_value MYSQL_USER)")"
  set_dash_env_value DB_PASSWORD "$(trim "$(get_env_value MYSQL_PASSWORD)")"
  set_dash_env_value DB_NAME "$(trim "$(get_env_value MYSQL_DATABASE)")"
}

ensure_mysql_credentials() {
  ensure_mysql_value MYSQL_DATABASE "dbmanager"
  ensure_mysql_value MYSQL_USER "db_admin"
  ensure_mysql_value MYSQL_READ_USER "db_read"
  ensure_mysql_secret MYSQL_ROOT_PASSWORD "$(generate_password_secret)"
  ensure_mysql_secret MYSQL_PASSWORD "$(generate_password_secret)"
  ensure_mysql_secret MYSQL_READ_PASSWORD "$(generate_password_secret)"
  sync_dashboard_database_env
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

ensure_docker_runtime() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  echo "Docker engine missing; installing via $PKG_MANAGER..."
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    install_packages docker.io
  elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
    install_packages docker
  else
    echo "Unable to install Docker automatically on this platform. Install Docker manually." >&2
    exit 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi
}

ensure_python3() {
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=$(command -v python3)
    return
  fi
  if [ -n "$PKG_MANAGER" ]; then
    install_packages python3
    if command -v python3 >/dev/null 2>&1; then
      PYTHON_BIN=$(command -v python3)
      return
    fi
  fi
  PYTHON_BIN=""
  echo "python3 is required for reliable port probing; falling back to ss/netstat if available." >&2
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi
  if [ -z "$PKG_MANAGER" ]; then
    echo "curl is required but no supported package manager was detected." >&2
    exit 1
  fi
  install_packages curl
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl remains unavailable; install it manually and re-run deploy.sh." >&2
    exit 1
  fi
}

fallback_install_com=()
fallback_install_compose() {
  local compose_version="2.29.2"
  local arch
  arch=$(uname -m)
  local binary
  case "$arch" in
    x86_64) binary="docker-compose-linux-x86_64" ;;
    aarch64|arm64) binary="docker-compose-linux-aarch64" ;;
    *) echo "Unsupported architecture $arch for docker-compose; install it manually." >&2
       return 1 ;;
  esac
  ensure_curl
  curl -L "https://github.com/docker/compose/releases/download/v${compose_version}/${binary}" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  hash -r
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
    return
  fi
  echo "Docker Compose missing; installing via $PKG_MANAGER..."
  if [ "$PKG_MANAGER" = "apt-get" ]; then
    if apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
      hash -r
      return
    fi
    echo "docker-compose-plugin unavailable via apt; falling back to GitHub binary."
    fallback_install_compose
    return
  elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
    if ${PKG_MANAGER} install -y docker-compose-plugin >/dev/null 2>&1; then
      hash -r
      return
    fi
  fi
  if ! fallback_install_compose; then
    echo "Docker Compose could not be installed automatically. Please install docker-compose manually." >&2
    exit 1
  fi
}

compose_service_uses_port() {
  local service=$1
  local host_port=$2
  if [ ${#COMPOSE_CMD[@]} -eq 0 ]; then
    return 1
  fi
  local container_id
  container_id=$(cd "$ROOT" && "${COMPOSE_CMD[@]}" -f "$DOCKER_COMPOSE_FILE" ps -q "$service" 2>/dev/null | head -n1)
  if [ -z "$container_id" ]; then
    return 1
  fi
  docker port "$container_id" 2>/dev/null | awk -v target="$host_port" '
    {
      split($3, parts, ":")
      if (parts[length(parts)] == target) {
        found = 1
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  '
}

port_in_use() {
  local port=$1
  if [ -n "$PYTHON_BIN" ]; then
    if "$PYTHON_BIN" - "$port" <<'PY'
import errno
import socket
import sys

class PortBusy(Exception):
    pass

def try_bind(family, addr):
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(addr)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            raise PortBusy
        if family == socket.AF_INET6 and exc.errno == errno.EAFNOSUPPORT:
            return
        raise
    finally:
        sock.close()

try:
    port_arg = int(sys.argv[1])
except (IndexError, ValueError):
    sys.exit(3)

try:
    try_bind(socket.AF_INET, ('0.0.0.0', port_arg))
    try_bind(socket.AF_INET6, ('::', port_arg))
except PortBusy:
    sys.exit(1)
except OSError as exc:
    print(f"Unable to verify port {port_arg}: {exc}", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
PY
    then
      return 1
    else
      local python_status=$?
      if [ "$python_status" -eq 1 ]; then
        return 0
      fi
      echo "Warning: port probe exited with $python_status for port $port; falling back to ss/netstat." >&2
    fi
  fi

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
  local service_name=${2:-}
  local max_port=${2:-65535}
  if [ -n "$service_name" ]; then
    max_port=${3:-65535}
  fi
  local port=$start_port
  while [ "$port" -le "$max_port" ]; do
    if ! port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
    if [ -n "$service_name" ] && compose_service_uses_port "$service_name" "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

nginx_paths() {
  local key=$1
  if [ -d "/etc/nginx/sites-available" ]; then
    case "$key" in
      available) printf '%s' "/etc/nginx/sites-available" ;;
      enabled) printf '%s' "/etc/nginx/sites-enabled" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  printf '%s' "/etc/nginx/conf.d"
}

nginx_reload() {
  nginx -t
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    if systemctl is-active --quiet nginx; then
      systemctl reload nginx
    else
      systemctl start nginx
    fi
  else
    nginx -s reload
  fi
}

proxy_pass_snippet() {
  local dashboard_port=$1
  local upstream_https=$2
  if [ "$upstream_https" = "true" ]; then
    cat <<EOF
    proxy_pass https://127.0.0.1:${dashboard_port};
    proxy_ssl_server_name on;
    proxy_ssl_verify off;
EOF
    return
  fi
  cat <<EOF
    proxy_pass http://127.0.0.1:${dashboard_port};
EOF
}

write_nginx_site() {
  local domain=$1
  local dashboard_port=$2
  local upstream_https=$3
  local mode=$4
  local sites_available
  local sites_enabled
  sites_available=$(nginx_paths available)
  sites_enabled=$(nginx_paths enabled)
  mkdir -p "$sites_available" "$sites_enabled" "$CERTBOT_WEBROOT"
  local conf_path="$sites_available/$NGINX_SITE_NAME"
  local proxy_block
  proxy_block=$(proxy_pass_snippet "$dashboard_port" "$upstream_https")

  if [ "$mode" = "bootstrap" ]; then
    cat <<NGINX > "$conf_path"
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location /.well-known/acme-challenge/ {
    root ${CERTBOT_WEBROOT};
  }

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
${proxy_block}
  }
}
NGINX
  else
    cat <<NGINX > "$conf_path"
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location /.well-known/acme-challenge/ {
    root ${CERTBOT_WEBROOT};
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name ${domain};

  ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  location /.well-known/acme-challenge/ {
    root ${CERTBOT_WEBROOT};
  }

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
${proxy_block}
  }
}
NGINX
  fi

  if [ "$sites_available" != "$sites_enabled" ]; then
    ln -sf "$conf_path" "$sites_enabled/$NGINX_SITE_NAME"
  fi

  if [ -e "$sites_enabled/default" ]; then
    rm -f "$sites_enabled/default"
  fi
}

ensure_nginx_site() {
  local domain=$1
  local dashboard_port=$2
  local upstream_https=$3
  local mode=$4
  write_nginx_site "$domain" "$dashboard_port" "$upstream_https" "$mode"
  nginx_reload
}

certificates_exist() {
  local domain=$1
  [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]
}

obtain_ssl_certificate() {
  local domain=$1
  local email=$2
  mkdir -p "$CERTBOT_WEBROOT"
  certbot certonly \
    --webroot \
    --webroot-path "$CERTBOT_WEBROOT" \
    --keep-until-expiring \
    --agree-tos \
    --noninteractive \
    --email "$email" \
    -d "$domain"
}

wait_for_dashboard() {
  local dashboard_port=$1
  local upstream_https=$2
  local max_attempts=${3:-30}
  local scheme="http"
  local curl_args=(-fsS)
  if [ "$upstream_https" = "true" ]; then
    scheme="https"
    curl_args+=(-k)
  fi
  ensure_curl
  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if curl "${curl_args[@]}" "${scheme}://127.0.0.1:${dashboard_port}/api/status" >/dev/null 2>&1; then
      echo "Dashboard is responding on ${scheme}://127.0.0.1:${dashboard_port}."
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "Dashboard did not become ready on ${scheme}://127.0.0.1:${dashboard_port}." >&2
  return 1
}

verify_https_proxy() {
  local domain=$1
  ensure_curl
  if curl -fsS --resolve "${domain}:443:127.0.0.1" "https://${domain}/api/status" >/dev/null 2>&1; then
    echo "Verified nginx is serving https://${domain}/api/status."
    return 0
  fi
  echo "nginx did not successfully proxy https://${domain}/api/status." >&2
  return 1
}

main() {
  ensure_env_file
  if [ ! -f "$DASH_ENV" ]; then
    cp "$DASH_ENV_EX" "$DASH_ENV"
    echo "Created dashboard/.env from template. deploy.sh will seed private dashboard credentials and SESSION_SECRET locally."
  fi

  detect_package_manager
  ensure_python3
  ensure_mysql_credentials
  ensure_session_secret
  ensure_dashboard_credentials
  set_dash_env_value APP_BUILD_ID "$(generate_app_build_id)"

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

  local skip_tls
  skip_tls=$(trim "$(get_dash_env_value SKIP_INTERNAL_TLS)")
  local upstream_https
  if [ "$skip_tls" = "true" ]; then
    upstream_https=false
  else
    upstream_https=true
  fi

  if [ -z "$PKG_MANAGER" ] && ! command -v nginx >/dev/null 2>&1; then
    echo "No automatic package manager detected. Install nginx manually before running deploy.sh." >&2
    exit 1
  fi
  ensure_docker_runtime
  ensure_docker_compose
  ensure_compose_command

  local mysql_port_pref
  mysql_port_pref=$(trim "$(get_env_value MYSQL_PORT)")
  mysql_port_pref=${mysql_port_pref:-3306}
  local mysql_port
  if ! mysql_port=$(find_available_port "$mysql_port_pref" "mysql"); then
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
  if ! dashboard_port=$(find_available_port "$dashboard_port_pref" "dashboard"); then
    echo "Unable to find a free port for the dashboard starting at $dashboard_port_pref. Please free some ports and re-run deploy.sh." >&2
    exit 1
  fi
  set_env_value DASHBOARD_PORT "$dashboard_port"
  if [ "$dashboard_port" != "$dashboard_port_pref" ]; then
    echo "Dashboard port $dashboard_port_pref was in use; switching to $dashboard_port."
  else
    echo "Using dashboard port $dashboard_port."
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
    install_packages certbot
  else
    echo "certbot already installed."
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    echo "certbot is still unavailable; please install it manually before running deploy.sh." >&2
    exit 1
  fi

  echo "Configuring nginx bootstrap site for certificate validation..."
  ensure_nginx_site "$domain" "$dashboard_port" "$upstream_https" "bootstrap"

  if certificates_exist "$domain"; then
    echo "Certificate for $domain already exists. Reusing the current files."
  else
    echo "Obtaining a Let's Encrypt certificate for $domain..."
    obtain_ssl_certificate "$domain" "$cert_email"
  fi
  if ! certificates_exist "$domain"; then
    echo "Certificate files for $domain were not found after certbot ran." >&2
    exit 1
  fi

  echo "Generating internal TLS certs for MySQL and the dashboard..."
  "$ROOT/scripts/generate-certs.sh"

  echo "Bringing up docker compose stack..."
  "${COMPOSE_CMD[@]}" -f "$DOCKER_COMPOSE_FILE" up -d --build

  wait_for_dashboard "$dashboard_port" "$upstream_https"

  echo "Applying the final HTTPS nginx configuration..."
  ensure_nginx_site "$domain" "$dashboard_port" "$upstream_https" "final"
  verify_https_proxy "$domain"

  echo "Deployment complete. Dashboard should be available over HTTPS at https://$domain."
  echo "Make sure the firewall allows ports 80 and 443 and keep $ENV_FILE and dashboard/.env out of source control."
}

main "$@"
