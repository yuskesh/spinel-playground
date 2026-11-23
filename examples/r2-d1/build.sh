#!/bin/bash
# examples/r2-d1 -- a practical sample of R2 (bytes) + D1 (SQL).
#
#   ./build.sh            -> generates a Workers project in dist/
#   (cd dist && npx wrangler dev --local)   → http://localhost:8787/
#
# Requires: vendor/spinel built (make deps && make), the wasi toolchain
# (brew install lld wasi-libc wasi-runtimes) and node. Details in examples/README.md.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
"$ROOT/tools/wasm/spinel-wasm" "$HERE/app.rb" --emit-worker "$HERE/dist" --host-api
# The project's own wrangler.toml (with the R2/D1 bindings and SPINEL_HOST_* set) is authoritative
cp "$HERE/wrangler.toml" "$HERE/dist/wrangler.toml"
echo "r2-d1: built ($(wc -c < "$HERE/dist/app.wasm" | tr -d " ") bytes). next: (cd $HERE/dist && npx wrangler dev --local)"
