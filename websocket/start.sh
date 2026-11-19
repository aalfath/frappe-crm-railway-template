#!/bin/bash
# Frappe CRM websocket service for Railway (https://github.com/aalfath/frappe-crm-railway-template).
# Writes the bench config from environment variables and starts Frappe's Socket.IO server on port 9000.
# It authenticates each socket by calling the frappe-crm service's gunicorn over the private network.
set -euo pipefail
cd /home/frappe/frappe-bench
: "${REDIS_QUEUE_URL:?REDIS_QUEUE_URL is required}"
: "${BACKEND_HOST:?BACKEND_HOST is required (private domain of the frappe-crm service)}"
# Wait for Redis (the Socket.IO server exits if it can't subscribe at start).
env/bin/python - <<'PY'
import os, socket, time
from urllib.parse import urlparse
u = urlparse(os.environ["REDIS_QUEUE_URL"])
for _ in range(90):
    try:
        socket.create_connection((u.hostname, u.port or 6379), 3).close(); break
    except OSError:
        time.sleep(2)
PY
env/bin/python - <<'PY'
import json, os
conf = {
    "redis_queue": os.environ["REDIS_QUEUE_URL"],
    "redis_socketio": os.environ["REDIS_QUEUE_URL"],
    "redis_cache": os.environ.get("REDIS_CACHE_URL") or os.environ["REDIS_QUEUE_URL"],
    "webserver_host": "http://" + os.environ["BACKEND_HOST"],
    "webserver_port": 8000,
    "socketio_port": 9000,
}
json.dump(conf, open("sites/common_site_config.json", "w"), indent=1)
PY
echo "[frappe-crm-websocket] starting Socket.IO on :9000, backend http://${BACKEND_HOST}:8000"
exec node apps/frappe/socketio.js
