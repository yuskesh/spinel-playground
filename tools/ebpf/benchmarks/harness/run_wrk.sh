#!/bin/sh
# benchmarks/harness/run_wrk.sh
#
# wrk wrapper. Runs `wrk -t <threads> -c <conc> -d <duration> --latency <url>`
# and emits a single CSV row matching benchmarks/README.md schema. wrk is
# preferred over ab for latency tails because its event loop scales better,
# but it doesn't support a fixed request count -- caller specifies duration
# instead. We report the "requests" CSV column as the number wrk actually
# made during the wall-clock window.
#
# Usage:
#   ./run_wrk.sh <milestone> <url> <concurrency> <duration_seconds>
# Example:
#   ./run_wrk.sh M001 http://127.0.0.1:8080/ 100 30

set -u

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <milestone> <url> <concurrency> <duration_seconds>" >&2
  exit 1
fi

milestone="$1"
url="$2"
conc="$3"
dur="$4"

command -v wrk >/dev/null 2>&1 || { echo "error: wrk not found (apt install wrk)" >&2; exit 1; }

# Use one thread per CPU but cap at conc; minimum 1.
nthreads=$(nproc 2>/dev/null || echo 1)
[ "$nthreads" -gt "$conc" ] && nthreads="$conc"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
raw=$(wrk -t "$nthreads" -c "$conc" -d "${dur}s" --latency "$url" 2>&1)
wrk_status=$?

if [ "$wrk_status" -ne 0 ]; then
  echo "$ts,$milestone,$url,wrk,$conc,0,0,0,0,$conc"
  exit 0
fi

# Parsing notes for wrk output:
#   "Requests/sec:   12345.67"
#   "Latency Distribution"
#   "    50%    1.50ms"
#   "    99%   10.00ms"
#   "  Non-2xx or 3xx responses: K"  (only emitted when >0)
#   "  Socket errors: connect 0, read 0, write 0, timeout 0"

# Helper to convert wrk's latency unit (us/ms/s/m) to milliseconds.
to_ms() {
  v="$1"
  case "$v" in
    *us) awk "BEGIN { printf \"%.3f\", ${v%us} / 1000 }" ;;
    *ms) echo "${v%ms}" ;;
    *s)  awk "BEGIN { printf \"%.3f\", ${v%s} * 1000 }" ;;
    *m)  awk "BEGIN { printf \"%.3f\", ${v%m} * 60000 }" ;;
    *)   echo "$v" ;;
  esac
}

rps=$(printf "%s\n" "$raw" | awk '/Requests\/sec:/ { print $2; exit }')
p50_raw=$(printf "%s\n" "$raw" | awk '/^ *50% +[0-9.]+(us|ms|s|m)$/ { print $2; exit }')
p99_raw=$(printf "%s\n" "$raw" | awk '/^ *99% +[0-9.]+(us|ms|s|m)$/ { print $2; exit }')
total_reqs=$(printf "%s\n" "$raw" | awk '/[0-9]+ requests in /  { print $1; exit }')
non2xx=$(printf "%s\n" "$raw" | awk '/Non-2xx or 3xx responses:/ { print $4; exit }')
errs=$(printf "%s\n" "$raw" | awk '/Socket errors/ {
  for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+,?$/) gsub(",","",$i)
  # connect=$4, read=$6, write=$8, timeout=$10 (positions after "Socket errors: connect")
  print $4 + $6 + $8 + $10; exit
}')

[ -z "$rps" ]      && { echo "error: could not parse wrk rps" >&2; printf "%s\n" "$raw" >&2; exit 2; }
[ -z "$total_reqs" ] && total_reqs=0
[ -z "$non2xx" ]   && non2xx=0
[ -z "$errs" ]     && errs=0

p50=$(to_ms "${p50_raw:-0ms}")
p99=$(to_ms "${p99_raw:-0ms}")
failures=$(( non2xx + errs ))

echo "$ts,$milestone,$url,wrk,$conc,$total_reqs,$rps,$p50,$p99,$failures"
