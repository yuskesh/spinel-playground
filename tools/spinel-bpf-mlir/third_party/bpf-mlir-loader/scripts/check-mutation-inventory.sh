#!/bin/bash
# E060 stop-C: evaluate only the finite expectation reader, never a gate/root body.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HERE/build/tmp"
OUT="${1:-$(mktemp -d "$HERE/build/tmp/mutation-inventory.XXXXXX")}"
[ -d "$OUT" ] || mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE"/test/oracle && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$GO" test ./cmd/mutation-inventory)
(cd "$HERE"/test/oracle && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$GO" build -o "$OUT/reader" ./cmd/mutation-inventory)
"$OUT/reader" "$HERE" "$OUT/inventory.json"
