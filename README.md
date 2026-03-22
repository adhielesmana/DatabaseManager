# DatabaseManager Stack

This repository ships a Dockerized **MySQL server** with mandatory TLS and a **dashboard service** that lets you browse tables, run safe `SELECT` queries, and import/export CSVs through role-based authentication with superadmin/admin/user tiers.

## Key components
- **mysql**: `mysql:8.1` with `require_secure_transport=ON`, custom initialization scripts and TLS certificates generated under `certs/mysql`.
- **dashboard**: Node/Express TLS (or HTTP when a reverse proxy handles HTTPS) server with hard-coded roles, CSV tooling, and a minimal SPA (`dashboard/public`). It connects to MySQL over TLS using the certificates mounted at `/app/certs`.
- **scripts/generate-certs.sh**: generates a self-signed CA plus server certificates for MySQL and the dashboard. The dashboard still generates those certs even when the production TLS endpoint is served through Nginx.
- **deploy helpers**: `deploy.sh` performs a full automated rollout (nginx/certbot detection, domain prompt, TLS provisioning, docker compose bring-up) and `intelligent-deploy.sh` updates an existing installation.

## Deployment

### Environment files (automatic creation)
- The first time you run `deploy.sh`, it copies `.env.example` → `.env` and `dashboard/.env.example` → `dashboard/.env` if they are missing. You can also copy them manually before running the script if you prefer.
- Set `DOMAIN` inside `.env` to the public hostname that will serve the dashboard (or let `deploy.sh` prompt you once). Optionally set `CERT_EMAIL` before the first run; otherwise the script defaults to `admin@<domain>`.
- `deploy.sh` keeps `.env` and `dashboard/.env` secure (both are gitignored) and warns if `SESSION_SECRET` is still the placeholder so you can replace it.

### Primary deploy (run once)
1. `sudo ./deploy.sh`
   - Detects whether `nginx` and Certbot are installed; installs them if they are missing.
   - Configures a simple nginx site for your domain, obtains a Let’s Encrypt certificate via `certbot --nginx --redirect`, and reloads the service.
   - Adds `https://<domain>` to `dashboard/.env` → `ALLOWED_ORIGINS` and sets `SKIP_INTERNAL_TLS=true` so the dashboard expects to sit behind nginx while still talking to MySQL over TLS.
   - Generates the self-signed certificates (`scripts/generate-certs.sh`) required by MySQL and the dashboard container, then runs `docker compose up -d --build` to start the stack.
   - Leaves a reminder that ports 80/443 must be reachable and sensitive files remain out of version control.

### App updates
- Run `./intelligent-deploy.sh` whenever you need to pull new images/rebuild. It checks that `DOMAIN` exists in `.env`, pulls the newest containers, and runs `docker compose up -d --build` with the same compose files.

## Accessing the services
- **Dashboard**: visit `https://<DOMAIN>` after the `deploy.sh` completes. Nginx terminates TLS, forwards traffic to the dashboard, and the UI enforces role-based gating (superadmin can import/export CSVs).
- **MySQL**: the container exposes TLS on port `${MYSQL_PORT:-3306}`. Copy `certs/mysql/ca.pem` to any remote client and connect as:
  ```bash
  mysql \
    --host=HOST \
    --port=${MYSQL_PORT:-3306} \
    --user=db_admin \
    --password='<Adm1n@DB2026!>' \
    --ssl-ca=certs/mysql/ca.pem \
    --ssl-mode=VERIFY_CA
  ```
  Replace `HOST` with the machine hosting the stack. Use `db_read` for read-only access.

## Security notes
- MySQL enforces TLS (`require_secure_transport=ON`) and the dashboard connects to it using the CA under `/etc/mysql/ssl/ca.pem` even when internal TLS is skipped.
- The dashboard exposes `SKIP_INTERNAL_TLS=true` when behind nginx so the reverse proxy handles HTTPS, but it still runs with HTTP-only cookies (`secure`, `sameSite='none'`) and session-based auth.
- `deploy.sh` asks for a public domain only the first time and reuses the saved value thereafter; you are free to edit `.env` and rerun `deploy.sh` if the hostname changes.
- `.env`, `dashboard/.env`, and any generated certificate material live outside source control (see `.gitignore`). Never commit the real secrets.

## Next steps
- Layer a production-grade reverse proxy (Caddy, Traefik, or another nginx) if you need HTTP/2, OCSP stapling, or a multi-service gateway.
- Replace the hard-coded dashboard users with a database-driven store or Vault-integrated identity provider for better user management.
- Automate certificate rotation/backups for the `certs/` directory if you rotate the CA or Let’s Encrypt chain.
