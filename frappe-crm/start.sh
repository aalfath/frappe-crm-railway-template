#!/bin/bash
# Frappe CRM web service for Railway (https://github.com/aalfath/frappe-crm-railway-template).
# Runs nginx (public, on PORT), gunicorn (port 8000, also used by the websocket and scheduler services
# over the private network) and one background worker for every queue. The site folder lives on this
# service's volume. Railway volumes can't be shared between services, so the worker, which writes
# attachments and needs the site's encryption key, stays here.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITE="${FRAPPE_SITE:-crm.local}"
export PORT="${PORT:-8080}"

# 1. As root: make the Railway volume writable for the frappe user, then drop privileges.
if [ "$(id -u)" = "0" ]; then
  rm -r "$BENCH/sites/lost+found" 2>/dev/null || true
  if [ "$(stat -c %u "$BENCH/sites")" != "1000" ]; then chown -R frappe:root "$BENCH/sites"; fi
  chown -R frappe:root "$BENCH/logs" /etc/nginx/conf.d 2>/dev/null || true
  exec runuser -u frappe -- bash "$0" "$@"
fi

cd "$BENCH"
umask 0002
# Re-open stdout/stderr as pipes owned by frappe, so nginx can write to /dev/stdout and /dev/stderr.
exec > >(cat) 2> >(cat >&2)
log() { echo "[frappe-crm] $*"; }

: "${DB_HOST:?DB_HOST is required}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${REDIS_CACHE_URL:?REDIS_CACHE_URL is required}"
: "${REDIS_QUEUE_URL:?REDIS_QUEUE_URL is required}"
: "${SOCKETIO_HOST:?SOCKETIO_HOST is required (private domain of the websocket service)}"
DB_PORT="${DB_PORT:-3306}"
# Railway's private network is IPv6; listen on both families when the container has IPv6.
if [ -f /proc/net/if_inet6 ]; then BIND_ANY='[::]'; LISTEN6="listen [::]:$PORT;"; else BIND_ANY=0.0.0.0; LISTEN6=""; fi
DB_NAME="${DB_NAME:-frappe_crm}"

# 2. Bench files that upstream keeps in the shared sites folder.
ls -1 apps > sites/apps.txt
rm -rf sites/assets && ln -s "$BENCH/assets" sites/assets
[ -f sites/common_site_config.json ] || echo '{}' > sites/common_site_config.json

wait_for() { # url-or-host port name
  local i
  for i in $(seq 1 90); do
    if env/bin/python -c "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 3)" "$1" "$2" 2>/dev/null; then
      log "$3 is reachable"; return 0
    fi
    sleep 2
  done
  log "$3 at $1:$2 not reachable"; exit 1
}
hostport() { local h="${1##*@}"; h="${h#redis://}"; echo "${h%%/*}"; }
wait_for "$DB_HOST" "$DB_PORT" MariaDB
HP="$(hostport "$REDIS_CACHE_URL")"; wait_for "${HP%:*}" "${HP##*:}" "Redis cache"
HP="$(hostport "$REDIS_QUEUE_URL")"; wait_for "${HP%:*}" "${HP##*:}" "Redis queue"

bench set-config -g db_host "$DB_HOST" >/dev/null
bench set-config -gp db_port "$DB_PORT" >/dev/null
bench set-config -g redis_cache "$REDIS_CACHE_URL" >/dev/null
bench set-config -g redis_queue "$REDIS_QUEUE_URL" >/dev/null
bench set-config -g redis_socketio "$REDIS_QUEUE_URL" >/dev/null
bench set-config -gp socketio_port 9000 >/dev/null
bench set-config -g default_site "$SITE" >/dev/null

# While the site is being created or migrated (minutes), serve a holding page on PORT so Railway's
# health check passes and visitors see what's happening.
SETUP_PID=""
setup_page_start() {
  [ -n "$SETUP_PID" ] && return 0
  cat > /tmp/nginx-setup.conf <<NGINX
worker_processes 1;
pid /tmp/nginx-setup.pid;
error_log stderr;
events { worker_connections 64; }
http {
  access_log off;
  server {
    listen $PORT;
    $LISTEN6
    location = /api/method/ping { default_type application/json; return 200 '{"message":"pong"}'; }
    location / {
      default_type text/html;
      add_header Retry-After 30 always;
      return 503 '<!doctype html><meta http-equiv="refresh" content="20"><title>Frappe CRM is starting</title><p style="font-family:sans-serif;margin:3em">Frappe CRM is being set up (first start or upgrade). This takes a few minutes; the page reloads by itself.</p>';
    }
  }
}
NGINX
  nginx -c /tmp/nginx-setup.conf -g 'daemon off;' & SETUP_PID=$!
}
setup_page_stop() {
  [ -z "$SETUP_PID" ] && return 0
  kill -TERM "$SETUP_PID" 2>/dev/null; wait "$SETUP_PID" 2>/dev/null || true; SETUP_PID=""
}

# 3. Create the site on first start; migrate when the app versions change.
VERSION="$(ls -1 apps | while read -r a; do printf '%s=%s ' "$a" "$(env/bin/python -c "import $a; print($a.__version__)" 2>/dev/null)"; done)"
if [ ! -f "sites/$SITE/.railway-installed" ]; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required for the first start}"
  log "Creating site $SITE with Frappe CRM (first start, takes a few minutes)"
  setup_page_start
  bench new-site "$SITE" --force \
    --db-name "$DB_NAME" --db-password "$DB_PASSWORD" \
    --mariadb-user-host-login-scope='%' \
    --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app crm --set-default
  bench --site "$SITE" scheduler enable
  # Job types are stamped in the install timezone (Asia/Kolkata); if the site later uses a timezone
  # west of it, every job's first run lands hours in the future. Backdate so they run on the next tick.
  bench --site "$SITE" mariadb -e "UPDATE \`tabScheduled Job Type\` SET creation='2000-01-01' WHERE name > '' AND last_execution IS NULL"
  echo "$VERSION" > "sites/$SITE/.railway-version"
  touch "sites/$SITE/.railway-installed"
elif [ "$(cat "sites/$SITE/.railway-version" 2>/dev/null)" != "$VERSION" ]; then
  log "App versions changed ($VERSION), running bench migrate"
  setup_page_start
  bench --site "$SITE" migrate
  echo "$VERSION" > "sites/$SITE/.railway-version"
fi
bench use "$SITE" >/dev/null
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  bench --site "$SITE" set-config host_name "https://$RAILWAY_PUBLIC_DOMAIN" >/dev/null
fi

# 4. nginx config from the image's template. The websocket service is looked up through Railway's
# private DNS on every request (its address changes on each deploy), and Origin follows the request
# host so the Socket.IO server accepts it.
RESOLVER="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
case "$RESOLVER" in *:*) RESOLVER="[$RESOLVER]";; esac
export BACKEND=127.0.0.1:8000 SOCKETIO="$SOCKETIO_HOST:9000" NGINX_LISTEN_PORT="$PORT" \
  TRUST_UPSTREAM_FORWARDED_PROTO=on \
  UPSTREAM_REAL_IP_ADDRESS="${UPSTREAM_REAL_IP_ADDRESS:-0.0.0.0/0}" UPSTREAM_REAL_IP_HEADER=X-Forwarded-For \
  UPSTREAM_REAL_IP_RECURSIVE=off FRAPPE_SITE_NAME_HEADER="$SITE" PROXY_READ_TIMEOUT=120 \
  CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
# shellcheck disable=SC2016
envsubst '${BACKEND} ${SOCKETIO} ${NGINX_LISTEN_PORT} ${TRUST_UPSTREAM_FORWARDED_PROTO} ${UPSTREAM_REAL_IP_ADDRESS} ${UPSTREAM_REAL_IP_HEADER} ${UPSTREAM_REAL_IP_RECURSIVE} ${FRAPPE_SITE_NAME_HEADER} ${PROXY_READ_TIMEOUT} ${CLIENT_MAX_BODY_SIZE}' \
  < /templates/nginx/frappe.conf.template \
  | sed -e '/^upstream socketio-server {/,/^}/d' \
        -e "s#^\(\s*\)listen $PORT;#\1listen $PORT;\n\1$LISTEN6\n\1resolver $RESOLVER valid=10s ipv6=on;#" \
        -e "s#proxy_pass http://socketio-server;#set \$socketio_upstream http://$SOCKETIO;\n\t\tproxy_pass \$socketio_upstream;#" \
        -e 's#proxy_set_header Origin .*#proxy_set_header Origin $proxy_x_forwarded_proto://$host;#' \
  > /etc/nginx/conf.d/frappe.conf
sed -e "s/^worker_processes .*/worker_processes ${NGINX_WORKERS:-2};/" -e '/^worker_cpu_affinity/d' \
    -e 's#^\(\s*\)access_log .*#\1access_log /dev/stdout;#' -e 's#^error_log .*#error_log stderr;#' \
    -e 's#^pid .*#pid /tmp/nginx.pid;#' /etc/nginx/nginx.conf > /tmp/nginx.conf

setup_page_stop

# 5. Run every process; if one exits, stop the rest so Railway restarts the container.
pids=()
start() { log "starting $1"; shift; "$@" & pids+=($!); }
trap 'kill -TERM "${pids[@]}" 2>/dev/null; wait "${pids[@]}"; exit 0' TERM INT
start gunicorn env/bin/gunicorn --chdir="$BENCH/sites" --bind="$BIND_ANY:8000" \
  --threads="${GUNICORN_THREADS:-4}" --workers="${GUNICORN_WORKERS:-2}" --worker-class=gthread \
  --worker-tmp-dir=/dev/shm --timeout="${GUNICORN_TIMEOUT:-120}" --preload frappe.app:application
start worker bench worker --queue long,default,short
start nginx nginx -c /tmp/nginx.conf -g 'daemon off;'
set +e
wait -n "${pids[@]}"
code=$?
log "a process exited with code $code, stopping the container"
kill -TERM "${pids[@]}" 2>/dev/null
wait "${pids[@]}"
exit 1
