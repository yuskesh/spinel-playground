#!/bin/bash
# examples/mvc-blog -- builds it so that it can be started on a local workerd.
#
#   ./build.sh            -> generates a Workers project in dist/
#   (cd dist && npx wrangler dev --local)   → http://localhost:8787/posts
#
# Requires: vendor/spinel built (make deps && make), the wasi toolchain
# (brew install lld wasi-libc wasi-runtimes) and node. Details in examples/README.md.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
"$ROOT/tools/wasm/spinel-wasm" "$HERE/app.rb" --emit-worker "$HERE/dist" --host-api
# The project's own wrangler.toml (with SPINEL_CGI_HEADERS and the rest) is authoritative
cp "$HERE/wrangler.toml" "$HERE/dist/wrangler.toml"
echo "mvc-blog: built. next: (cd $HERE/dist && npx wrangler dev --local)"
