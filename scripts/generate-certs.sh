#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CERT_ROOT="$ROOT/certs"
MYSQL_CERT_DIR="$CERT_ROOT/mysql"
DASHBOARD_CERT_DIR="$CERT_ROOT/dashboard"
rm -rf "$MYSQL_CERT_DIR" "$DASHBOARD_CERT_DIR"
mkdir -p "$MYSQL_CERT_DIR" "$DASHBOARD_CERT_DIR"
CA_KEY="$CERT_ROOT/ca-key.pem"
CA_CERT="$CERT_ROOT/ca.pem"
openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
  -keyout "$CA_KEY" \
  -out "$CA_CERT" \
  -subj "/CN=DatabaseManager TLS CA"

generate_cert() {
  local prefix=$1
  local cn=$2
  local extfile=$3
  local key="$CERT_ROOT/${prefix}-key.pem"
  local csr="$CERT_ROOT/${prefix}.csr"
  local cert="$CERT_ROOT/${prefix}-cert.pem"
  openssl req -newkey rsa:4096 -nodes \
    -keyout "$key" \
    -out "$csr" \
    -subj "/CN=$cn"
  openssl x509 -req -days 3650 \
    -in "$csr" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$cert" \
    -extensions v3_req \
    -extfile "$extfile"
}

cat <<'EXT' > "$CERT_ROOT/mysql-ext.cnf"
[req]
prompt = no
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = mysql
DNS.2 = database
DNS.3 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EXT
cat <<'EXT' > "$CERT_ROOT/dashboard-ext.cnf"
[req]
prompt = no
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = dashboard
DNS.2 = localhost
DNS.3 = 0.0.0.0
IP.1 = 127.0.0.1
IP.2 = ::1
EXT

generate_cert mysql mysql "$CERT_ROOT/mysql-ext.cnf"
generate_cert dashboard dashboard "$CERT_ROOT/dashboard-ext.cnf"
cp "$CA_CERT" "$MYSQL_CERT_DIR/ca.pem"
cp "$CA_CERT" "$DASHBOARD_CERT_DIR/ca.pem"
cp "$CERT_ROOT/mysql-key.pem" "$MYSQL_CERT_DIR/server-key.pem"
cp "$CERT_ROOT/mysql-cert.pem" "$MYSQL_CERT_DIR/server-cert.pem"
cp "$CERT_ROOT/dashboard-key.pem" "$DASHBOARD_CERT_DIR/dashboard-key.pem"
cp "$CERT_ROOT/dashboard-cert.pem" "$DASHBOARD_CERT_DIR/dashboard-cert.pem"
rm -f "$CERT_ROOT"/*.csr "$CERT_ROOT"/*-ext.cnf
cat <<'MSG'
Certificates generated under $CERT_ROOT. Install $CA_CERT in each client and configure TLS.
MySQL uses ${MYSQL_CERT_DIR}/server-cert.pem, server-key.pem, ca.pem. Dashboard picks ${DASHBOARD_CERT_DIR} files.
MSG
