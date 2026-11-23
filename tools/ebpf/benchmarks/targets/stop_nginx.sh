#!/bin/sh
# benchmarks/targets/stop_nginx.sh
#
# Stop the M001 baseline nginx started by start_nginx.sh.

set -eu

PIDFILE=/tmp/nginx.pid
if [ -r "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        # Wait briefly for it to exit cleanly.
        for _ in 1 2 3 4 5; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
    fi
    rm -f "$PIDFILE"
    echo "[stop_nginx] stopped"
else
    echo "[stop_nginx] no pid file at $PIDFILE; nothing to do"
fi
