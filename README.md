[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/frappe-crm?utm_medium=integration&utm_source=button&utm_campaign=frappe-crm)

# Frappe CRM on Railway

Source for the [Frappe CRM](https://github.com/frappe/crm) Railway template. It deploys **Frappe CRM v16.1.0**
(Frappe Framework 16.60.2) as six services wired over Railway's private network.

| Service | Built from | What it does | Volume |
|---|---|---|---|
| `frappe-crm` (public) | [`frappe-crm/`](frappe-crm) | nginx on `PORT`, gunicorn on 8000, one background worker for every queue. Creates the site on first start and runs `bench migrate` after an upgrade | `/home/frappe/frappe-bench/sites` |
| `websocket` | [`websocket/`](websocket) | Frappe's Socket.IO server (port 9000) for realtime updates; nginx in `frappe-crm` proxies `/socket.io` to it | none |
| `scheduler` | [`scheduler/`](scheduler) | `bench schedule`: queues CRM's periodic jobs (lead syncing, overdue task alerts, email pulls) for the worker | none |
| `MariaDB` | `mariadb:11.8.9` (pinned digest) | Database, with the charset flags Frappe needs | `/var/lib/mysql` |
| `Redis-Cache` | Railway Redis | Cache | `/data` |
| `Redis-Queue` | Railway Redis | Job queue and realtime pub/sub | `/data` |

Every app service builds `FROM ghcr.io/frappe/crm:v16.1.0@sha256:8614fe0a…`. That upstream image contains only the
Frappe framework, so the Dockerfiles install the CRM app from the matching `v16.1.0` tag (`bench get-app`).
Railway volumes can't be shared between services, so the worker (which writes attachments and needs the site's
encryption key) runs inside `frappe-crm`; `websocket` and `scheduler` need no site files and get their settings
from variables.

## After deploy

Wait about 5 minutes for the first start (the site is created; the URL shows a "being set up" page meanwhile), then
open the `frappe-crm` domain and sign in as `Administrator` with the `ADMIN_PASSWORD` variable of the `frappe-crm`
service. The CRM lives at `/crm`; Frappe's admin desk at `/app`.

## Variables

| Service | Variable | Value |
|---|---|---|
| frappe-crm | `ADMIN_PASSWORD` | generated, password of `Administrator` (used on first start only) |
| frappe-crm | `DB_PASSWORD` | generated, password of the site's own MariaDB user |
| frappe-crm | `DB_HOST`, `DB_ROOT_PASSWORD` | references to `MariaDB` (root is used to create the site database) |
| frappe-crm, websocket, scheduler | `REDIS_CACHE_URL`, `REDIS_QUEUE_URL` | references to `Redis-Cache` and `Redis-Queue` |
| frappe-crm | `SOCKETIO_HOST` | private domain of `websocket` |
| websocket, scheduler | `BACKEND_HOST` | private domain of `frappe-crm` |
| frappe-crm | `PORT`, `RAILWAY_RUN_UID` | `8080`; `0` so the start script can fix the volume's owner before dropping to the `frappe` user |
| MariaDB | `MARIADB_ROOT_PASSWORD` | generated |

Optional tuning on `frappe-crm`: `GUNICORN_WORKERS` (2), `GUNICORN_THREADS` (4), `NGINX_WORKERS` (2), `CLIENT_MAX_BODY_SIZE` (50m).
Email and Twilio/Exotel calling are set up inside the CRM's settings after deploy. WhatsApp needs Frappe's separate `frappe/whatsapp` app, which this template does not install.

## Updates

A merge to `main` here makes Railway offer an update to everyone who deployed the template. Read
[CHANGELOG.md](CHANGELOG.md) first: back up MariaDB and the `frappe-crm` volume, then apply the update. On the next
start, `frappe-crm` sees the new app versions and runs `bench migrate` before it serves traffic.

## Local test

`docker compose -f compose.test.yml up --build` runs the same layout locally on port 8080; set the `TEST_*` password variables listed at the top of that file first.

MIT licensed wrapper. Frappe CRM is AGPL-3.0 and the Frappe Framework MIT, both by Frappe Technologies.
