#!/usr/bin/env bash
# examples/edge-twin -- the demo.  ./build.sh first.
#
#   ./run_demo.sh              device (QEMU) + edge (workerd), the whole story
#   ./run_demo.sh --edge-only  skip QEMU and use the worker's own /stream
#
# What it shows, in order:
#   1. a Cortex-M33 running the kernel writes 1048 rows of audit log
#   2. an edge worker running THE SAME kernel replays it and accepts it
#   3. three forged logs, and the row on which each one is caught
#   4. a reading outside the declared domain: the device panics, the edge
#      answers 422 and stays up
#
# Nothing here is timed, no real device is used (QEMU) and no real edge is used
# (`wrangler dev --local`: workerd on this machine, no account, no network).
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
PORT=${PORT:-8788}
# The Zephyr build trees live outside the repository (see build.sh).
OUT=${EDGE_TWIN_BUILD:-${TMPDIR:-/tmp}/spinel-edge-twin}
WORK=${WORK:-$OUT/demo}
EDGE_ONLY=0
[ "${1:-}" = "--edge-only" ] && EDGE_ONLY=1

[ -f "$HERE/dist/kern.wasm" ] || { echo "run ./build.sh first" >&2; exit 1; }
mkdir -p "$WORK"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# `west build -t run` never returns (the board idles after main), so wait for a
# sentinel in the log and then stop QEMU through the pid file Zephyr's run target
# locks -- killing ninja alone leaves qemu holding it, and the next run of the
# same board fails with "cannot create PID file".
qemu_run() {   # $1 = build dir, $2 = log, $3 = sentinel
  local dir=$1 log=$2 sentinel=$3 pid
  qemu_stop "$dir"
  west build -d "$dir" -t run > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 240); do
    grep -q "$sentinel" "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  sleep 1; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  qemu_stop "$dir"
}
qemu_stop() {
  [ -f "$1/qemu.pid" ] && kill "$(cat "$1/qemu.pid" 2>/dev/null)" 2>/dev/null
  rm -f "$1/qemu.pid"
  sleep 1
}

# --- the edge --------------------------------------------------------------
say "starting workerd (wrangler dev --local) on :$PORT"
(cd "$HERE/dist" && npx wrangler dev --port "$PORT" --ip 127.0.0.1 > "$WORK/wrangler.log" 2>&1) &
WPID=$!
cleanup() { pkill -P "$WPID" 2>/dev/null; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
trap cleanup EXIT
for _ in $(seq 1 60); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 1
done
curl -s -m 5 "http://127.0.0.1:$PORT/" | head -2

# --- 1. the device ---------------------------------------------------------
LOG=$WORK/audit_device.log
if [ "$EDGE_ONLY" = 0 ] && [ -d "$OUT/dev-m33" ]; then
  say "the device: QEMU Cortex-M33 (Zephyr) writes an audit log"
  export ZEPHYR_BASE="${ZEPHYR_BASE:-}"
  export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-}"
  export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
  RAW=$WORK/qemu.log
  : > "$RAW"
  # The board idles after main(), so wait for the trailer rather than for a
  # timeout, then stop QEMU by its own pid file (Zephyr's run target locks it,
  # and a qemu that outlives ninja blocks the next run of the same board).
  qemu_run "$OUT/dev-m33" "$RAW" '#final'
  grep '^E067	' "$RAW" | cut -f2- | tr -d '\r' > "$LOG"
  echo "device wrote $(wc -l < "$LOG" | tr -d ' ') lines"
else
  say "the edge produces the log itself (GET /stream) -- the same kernel"
  curl -s -m 30 "http://127.0.0.1:$PORT/stream" > "$LOG"
fi
head -3 "$LOG"; echo "..."; tail -2 "$LOG"

# --- 2. the replay ---------------------------------------------------------
say "the edge replays it: POST /audit"
curl -s -m 30 -w '\nHTTP %{http_code}\n' -X POST --data-binary "@$LOG" \
     "http://127.0.0.1:$PORT/audit" | head -14

# --- 3. the forgeries ------------------------------------------------------
forge() {   # $1 = id, $2 = Ruby expression over the row list `B`
  ruby "$ROOT/examples/tools/forge.rb" "$LOG" "$WORK/$1.log" "$2"
}
post() {   # $1 = id, $2 = description
  printf '\n  \033[1m%s\033[0m -- %s\n' "$1" "$2"
  curl -s -m 30 -w '\n  HTTP %{http_code}\n' -X POST --data-binary "@$WORK/$1.log" \
       "http://127.0.0.1:$PORT/audit" \
    | ruby "$ROOT/examples/tools/post_fmt.rb"
}

say "three forgeries, replayed on the edge"
forge t1_sample  'B[500][1] = (Integer(B[500][1], 10) + 1).to_s'
post t1_sample "one reading raised by 1 milli-degree"
forge t2_verdict 'i = B.each_index.select { |j| B[j][2] == "2" }[1]; B[i][2] = "0"'
post t2_verdict "an alarm relabelled as normal"
forge t3_droprow 'B.delete_at(300)
(300...B.size).each { |j| B[j][0] = j.to_s }'
post t3_droprow "a row deleted and the indices renumbered"

# --- 4. the trap, on both sides -------------------------------------------
say "a reading outside the declared domain (|x| <= 100000)"
forge x1_domain  'B[900][1] = "2000000000"'
post x1_domain "the EDGE: the kernel traps, the worker answers 422 and stays up"
printf '  and it is still serving: /probe?x=25000 -> %s\n' \
       "$(curl -s -m 10 "http://127.0.0.1:$PORT/probe?x=25000")"

if [ "$EDGE_ONLY" = 0 ] && [ -d "$OUT/dev-trap" ]; then
  printf '\n  \033[1mthe DEVICE: the same overflow, on the microcontroller\033[0m\n'
  RAW=$WORK/qemu_trap.log
  : > "$RAW"
  qemu_run "$OUT/dev-trap" "$RAW" 'Faulting instruction\|PANIC\|Halting'
  grep -E '^E067|Faulting instruction' "$RAW" | tr -d '\r' | sed 's/^/  /'
  grep -q '#UNREACHABLE' "$RAW" \
    && echo "  !! execution continued past the trap" \
    || echo "  (nothing after the trapping call ran: the same contract, a fatal platform)"
fi

say "done"
echo "the worker is still up at http://127.0.0.1:$PORT while this script exits."
