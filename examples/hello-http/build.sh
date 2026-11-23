#!/bin/bash
# examples/hello-http -- a minimal HTTP echo: the CGI contract in its plainest form.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
exec "$ROOT/tools/wasm/spinel-wasm" "$HERE/app.rb" --emit-worker "$HERE/dist"
