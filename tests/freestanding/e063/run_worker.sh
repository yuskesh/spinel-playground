#!/usr/bin/env bash
# E063: the workerd leg, ported from spinel-llvm 463d49dd
# docs/experiments/results/E063/run_worker.sh. build.sh and run_gates.sh first.
#
# `wrangler dev` is local: it runs workerd on this machine with no account and
# no network. The probe worker imports the SAME kern.wasm the node leg ran, and
# its results are compared with node.tsv: our module under a second runtime,
# not another implementation. Nothing is timed.
#
#   bash run_worker.sh        -> $RES/workerd.tsv, $RES/workerd_dev.log
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_wasm
PORT=${PORT:-8791}
WRANGLER=${WRANGLER:-wrangler}
command -v "$WRANGLER" >/dev/null 2>&1 || { echo "run_worker: no wrangler ('$WRANGLER')" >&2; exit 2; }
LOG=$OUT/wrangler.log
[ -f "$OUT/probe/kern.wasm" ] && [ -f "$OUT/probe/sig.json" ] || {
  echo "run_worker: no probe module; run build.sh first" >&2; exit 2; }
cd "$OUT/probe"
"$WRANGLER" dev --port "$PORT" --ip 127.0.0.1 > "$LOG" 2>&1 &
WPID=$!
cleanup() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
trap cleanup EXIT
for _ in $(seq 1 60); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 1
done
if ! curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/"; then
  echo "run_worker: wrangler dev did not come up; see $LOG" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
grep -m1 "wrangler " "$LOG" | tr -d '\r' | sed 's/^/wrangler: /'

"$NODE" "$HERE/worker_probe.mjs" "http://127.0.0.1:$PORT" \
     "$RES/cases.json" "$RES/node.tsv" > "$RES/workerd.tsv"
rc=$?
cp "$LOG" "$RES/workerd_dev.log"
awk -F'\t' 'NR>1{n[$5]++} END{for (k in n) printf "%s=%d ", k, n[k]; print ""}' \
    "$RES/workerd.tsv"
exit $rc
