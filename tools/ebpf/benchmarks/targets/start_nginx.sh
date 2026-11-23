#!/bin/sh
# benchmarks/targets/start_nginx.sh
#
# Install (if necessary) and start the M001 baseline nginx with the
# benchmarks/targets/nginx_hello.conf config. Idempotent: re-running stops
# any existing nginx process first.
#
# Designed to run inside the debian-trixie build container that the harness
# uses (apt available, root user).

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HERE/nginx_hello.conf"
PIDFILE=/tmp/nginx.pid

# Install if missing.
if ! command -v nginx >/dev/null 2>&1; then
    echo "[start_nginx] installing nginx..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nginx >/dev/null
fi

# Stop any existing baseline instance for idempotency.
if [ -r "$PIDFILE" ]; then
    OLDPID=$(cat "$PIDFILE")
    if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
        echo "[start_nginx] stopping existing nginx pid=$OLDPID"
        kill "$OLDPID"
        # Wait for it to actually exit.
        for _ in 1 2 3 4 5; do
            kill -0 "$OLDPID" 2>/dev/null || break
            sleep 0.2
        done
    fi
    rm -f "$PIDFILE"
fi

# Start the baseline nginx in daemon mode using our conf.
nginx -c "$CONF" -e /tmp/nginx_error.log
sleep 0.2

# Verify it actually came up.
if ! curl -fsS -o /dev/null http://127.0.0.1:8080/; then
    echo "[start_nginx] nginx failed to respond on 127.0.0.1:8080" >&2
    tail -20 /tmp/nginx_error.log 2>/dev/null >&2 || true
    exit 1
fi
echo "[start_nginx] nginx baseline listening on 127.0.0.1:8080 (pid=$(cat $PIDFILE))"
