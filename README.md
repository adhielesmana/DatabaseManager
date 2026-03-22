![MySQL](https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/MySQL_logo.svg/160px-MySQL_logo.svg.png) ![Docker](https://www.docker.com/wp-content/uploads/2022/03/Moby-logo.png) ![Node.js](https://upload.wikimedia.org/wikipedia/commons/d/d9/Node.js_logo.svg)

# DatabaseManager Stack

<span style="color:#0d6efd">Secure</span> · <span style="color:#198754">TLS-first</span> · <span style="color:#d63384">role-aware</span>

Deliver a hardened MySQL server behind TLS plus a management dashboard that lets your team read schemas, run scoped `SELECT` queries, and ingest/export CSVs. Everything ships as Docker Compose services, and `deploy.sh` automates nginx/certbot/nginx, certificates, and stack launch while `intelligent-deploy.sh` catches updates.

## Why this stack?

| Concern | What you get |
|--------|-------------|
| **Encrypted transport everywhere** | MySQL runs with `require_secure_transport` plus custom CA/signed certs, while the dashboard is reachable over HTTPS (or via nginx when `SKIP_INTERNAL_TLS=true`).
| **Role-based UX** | Superadmin, admin, and user roles gate import/export, query tooling, and what’s shown in the SPA (`dashboard/server/index.js`).
| **Remote-ready operations** | `deploy.sh` detects host packages, obtains Let’s Encrypt certs, and sources `DOMAIN`/`CERT_EMAIL` once; `intelligent-deploy.sh` simply updates containers via Docker Compose.
| **Auditable changes** | All secrets live in `.env` / `dashboard/.env`, which are gitignored and seeded from the `.example` templates.

## Stack architecture

```mermaid
flowchart LR
  subgraph Host
    nginx[Nginx (TLS + reverse proxy)]
    certbot[Certbot/Let’s Encrypt]
    docker[Docker Engine]
  end
  subgraph Containers
    mysql[MySQL 8.1 with leaked CA]
    dashboard[Node.js Dashboard]
  end
  nginx -->|proxy| dashboard
  dashboard -->|SSL| mysql
  docker --> mysql
  docker --> dashboard
  certbot --> nginx
  mysql --bind SSL--> clients([Remote clients over TLS])
```

> Colors: nginx (blue), dashboard (green), MySQL (orange). The dashboard still generates internal certs (for `SKIP_INTERNAL_TLS=false`), even when nginx terminates TLS.

## Deployment workflow

1. **Prepare**: copy `.env.example` → `.env` and `dashboard/.env.example` → `dashboard/.env` if you prefer to edit offline.
2. **First install**: run `sudo ./deploy.sh`. It will:
   - prompt once for `DOMAIN` (or re-use existing value and skip the prompt thereafter), set `CERT_EMAIL`, and append origins to `ALLOWED_ORIGINS`.
   - detect/ install `nginx` + `certbot` if missing, and configure a lightweight site that proxies `https://<DOMAIN>` to the dashboard.
   - run `certbot --nginx --redirect` to grab certs, set `SKIP_INTERNAL_TLS=true`, and generate the CA/certs required by the containers.
   - bring up the Compose stack (`docker compose up -d --build`).
3. **Updates**: run `./intelligent-deploy.sh` (no sudo). It ensures `DOMAIN` exists and simply pulls + rebuilds the Compose services.

## Runtime operations

- **Dashboard access**: visit `https://<DOMAIN>` and authenticate with the credentials defined in `dashboard/server/index.js`; change them there whenever you rotate user roles.
- **MySQL access**: copy `certs/mysql/ca.pem` to remote clients and connect over TLS on `${MYSQL_PORT:-3306}`, supplying the username/password you set in `.env` (`db_admin`/`db_read`).
- **Logs**: inspect `docker compose logs mysql` and `docker compose logs dashboard` for service output; `deploy.sh` and `intelligent-deploy.sh` already run `docker compose up -d --build`, so `down/up` can be used for full restarts.

## Security notes

- Session cookies are `secure`, `httpOnly`, and `sameSite='none'` to work behind TLS proxies.
- The dashboard enforces `SKIP_INTERNAL_TLS` when nginx handles HTTPS, but it still reaches MySQL over TLS using the generated CA.
- `.env`, `.dashboard/.env`, and `certs/` are excluded from git; never commit them.
- Rotate the CA/certs by re-running `scripts/generate-certs.sh` and restarting the stack.

## Next steps

- Integrate with Vault or IAM for user management instead of the hard-coded dashboard users.
- Put nginx/certbot behind Caddy or Traefik if you need multi-domain routing, OCSP stapling, or HTTP/2.
- Automate certificate rotation/backups for `certs/` and refresh the CA when your infrastructure changes.
