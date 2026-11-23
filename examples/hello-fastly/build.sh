#!/bin/bash
# examples/hello-fastly -- ONE Ruby program, two edge platforms.
#
# Builds app.rb twice from the same source with no edit in between:
#
#   dist/          a Fastly Compute package   (fastly compute serve)
#   dist-workers/  a Cloudflare Workers project (wrangler dev --local)
#
# The .wasm files are NOT the same file -- a Fastly guest carries the E013
# lifecycle layer inside the module, a Workers one gets it from worker.mjs --
# but the Ruby is, and /echo, /info and /kv answer byte for byte identically
# (E058).
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
SW="$ROOT/tools/wasm/spinel-wasm"

"$SW" "$HERE/app.rb" --emit-fastly "$HERE/dist"         --host-api
"$SW" "$HERE/app.rb" --emit-worker "$HERE/dist-workers" --host-api

# The Fastly side needs nothing more: the scaffolded fastly.toml already
# declares the `origin` backend, the `app_kv` KV Store and the `spinel` Config
# Store, because on Fastly those declarations ARE the deployment.
#
# The Workers side needs the matching bindings, and the scaffolded
# wrangler.toml deliberately does not invent them (re-running --emit-worker
# must never overwrite a deployment's own file).  Add them once, here, so the
# two sides are configured equivalently and the comparison is fair.
W="$HERE/dist-workers/wrangler.toml"
# ^SPINEL_HOST_KV, anchored: the scaffolded wrangler.toml MENTIONS the name in
# a comment block listing the available knobs, so an unanchored grep would
# match its own documentation and skip the edit forever.
if ! grep -qE '^SPINEL_HOST_KV' "$W"; then
  cat >> "$W" <<'TOML'

# ---- added by build.sh so the Workers side matches the Fastly side ----------
# app_kv          <-> [local_server.kv_stores] app_kv
# ORIGIN_URL      <-> [local_server.backends.origin] url
# ORIGIN_BACKEND  <-> the backend name itself (ignored on Workers, required on
#                     Fastly -- the program passes it either way)
# SPINEL_CGI_HEADERS <-> the `spinel` Config Store key of the same name
[[kv_namespaces]]
binding = "app_kv"
id = "e058e058e058e058e058e058e058e058"
TOML
  ruby -e '
    p = ARGV[0]
    s = File.binread(p)
    s = s.sub(%q{GREETING = "hello from wrangler.toml"},
              %Q{GREETING = "hello from wrangler.toml"\n} +
              %Q{SPINEL_CGI_HEADERS = "1"\n} +
              %Q{SPINEL_HOST_KV = "app_kv"\n} +
              %Q{ORIGIN_URL = "http://127.0.0.1:7899/probe"\n} +
              %q{ORIGIN_BACKEND = "origin"})
    File.binwrite(p, s)
  ' "$W"
  echo "build.sh: added the KV binding and vars to dist-workers/wrangler.toml" >&2
fi

cat >&2 <<EOF

next:
  # Fastly (Viceroy) -- needs the fastly CLI + \`fastly compute install-tools\`
  (cd $HERE/dist && fastly compute serve --skip-build)
  curl 'http://127.0.0.1:7676/info?a=1&b=2'

  # Cloudflare Workers (workerd)
  (cd $HERE/dist-workers && npx wrangler dev --local)
  curl 'http://localhost:8787/info?a=1&b=2'

  # /fetch on either side wants something on 127.0.0.1:7899; see README.md
EOF
