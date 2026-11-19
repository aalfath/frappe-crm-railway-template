#!/bin/bash
# Frappe CRM scheduler service for Railway (https://github.com/aalfath/frappe-crm-railway-template).
# Rebuilds the site's database settings from environment variables (no shared volume needed),
# waits until the frappe-crm service has created the site, then runs `bench schedule`.
set -euo pipefail
cd /home/frappe/frappe-bench
log() { echo "[frappe-crm-scheduler] $*"; }
SITE="${FRAPPE_SITE:-crm.local}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${REDIS_CACHE_URL:?REDIS_CACHE_URL is required}"
: "${REDIS_QUEUE_URL:?REDIS_QUEUE_URL is required}"
: "${BACKEND_HOST:?BACKEND_HOST is required (private domain of the frappe-crm service)}"
export SITE DB_NAME="${DB_NAME:-frappe_crm}" DB_PORT="${DB_PORT:-3306}"
ls -1 apps > sites/apps.txt
mkdir -p "sites/$SITE"
env/bin/python - <<'PY'
import json, os
e = os.environ
json.dump({
    "db_host": e["DB_HOST"], "db_port": int(e["DB_PORT"]),
    "redis_cache": e["REDIS_CACHE_URL"], "redis_queue": e["REDIS_QUEUE_URL"],
    "redis_socketio": e["REDIS_QUEUE_URL"], "socketio_port": 9000,
    "default_site": e["SITE"],
}, open("sites/common_site_config.json", "w"), indent=1)
json.dump({"db_name": e["DB_NAME"], "db_user": e["DB_NAME"], "db_password": e["DB_PASSWORD"]},
          open(f"sites/{e['SITE']}/site_config.json", "w"), indent=1)
PY
echo "$SITE" > sites/currentsite.txt

# The site exists once the web service's gunicorn answers for it (first start takes a few minutes).
log "waiting for the frappe-crm service to finish setting up the site"
until curl -fsS -m 5 -H "X-Frappe-Site-Name: $SITE" "http://${BACKEND_HOST}:8000/api/method/ping" >/dev/null 2>&1; do sleep 10; done
log "site is up; starting bench schedule"
exec bench schedule
