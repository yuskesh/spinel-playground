#!/bin/bash
# examples/fetch-kv -- a minimal example of Edge::HTTP.request and KV (the host bridge).
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
exec "$ROOT/tools/wasm/spinel-wasm" "$HERE/app.rb" --emit-worker "$HERE/dist" --host-api
