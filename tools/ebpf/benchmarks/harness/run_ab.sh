#!/bin/sh
# benchmarks/harness/run_ab.sh
#
# Apache Bench wrapper. Runs `ab -c <conc> -n <reqs> <url>` and emits a single
# CSV row matching the schema documented in benchmarks/README.md.
#
# Usage:
#   ./run_ab.sh <milestone> <url> <concurrency> <requests>
# Example:
#   ./run_ab.sh M001 http://127.0.0.1:8080/ 100 10000
#
# Failure modes:
#   - ab not installed              -> exits 1
#   - ab returns non-zero            -> emits CSV with rps=0 failures=<reqs>
#   - parse fails (unexpected format) -> exits 2 (so missing data is loud)

set -u

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <milestone> <url> <concurrency> <requests>" >&2
  exit 1
fi

milestone="$1"
url="$2"
conc="$3"
reqs="$4"

command -v ab >/dev/null 2>&1 || { echo "error: ab not found (apt install apache2-utils)" >&2; exit 1; }

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
raw=$(ab -c "$conc" -n "$reqs" -q "$url" 2>&1)
ab_status=$?

if [ "$ab_status" -ne 0 ]; then
  # Emit a row marking the entire run as failed so we don't silently drop data.
  echo "$ts,$milestone,$url,ab,$conc,$reqs,0,0,0,$reqs"
  exit 0
fi

# Parsing notes:
# - "Requests per second: 12345.67 [#/sec] (mean)"
# - Percentile table:
#     "50%   N"
#     "99%   M"
# - "Failed requests:   K"
# - "Non-2xx responses: J"  (only emitted when >0)

rps=$(printf "%s\n" "$raw" | awk '/Requests per second:/ { print $4; exit }')
p50=$(printf "%s\n" "$raw" | awk '/^ *50% +[0-9]+/ { print $2; exit }')
p99=$(printf "%s\n" "$raw" | awk '/^ *99% +[0-9]+/ { print $2; exit }')
fail=$(printf "%s\n" "$raw" | awk '/Failed requests:/ { print $3; exit }')
non2xx=$(printf "%s\n" "$raw" | awk '/Non-2xx responses:/ { print $3; exit }')

[ -z "$rps" ]  && { echo "error: could not parse rps from ab output" >&2; printf "%s\n" "$raw" >&2; exit 2; }
[ -z "$p50" ]  && p50=0
[ -z "$p99" ]  && p99=0
[ -z "$fail" ] && fail=0
[ -z "$non2xx" ] && non2xx=0

failures=$(( fail + non2xx ))

echo "$ts,$milestone,$url,ab,$conc,$reqs,$rps,$p50,$p99,$failures"
