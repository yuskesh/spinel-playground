#!/bin/bash
# examples/gatekeeper -- build BOTH modules and wire them into one Worker.
#
#   dist/kern.wasm   ~2 KB   freestanding (P003 profile wasm32-worker, E063)
#   dist/app.wasm  ~245 KB   full Ruby   (E013 CGI contract)
#
# The two come out of the same compiler and the same repo, through two
# different back ends, and the whole example is about the fact that the request
# path meets the small one first.
#
#   ./build.sh
#   cd dist && npx wrangler dev --local
#   curl -H 'x-user-id: alice' -H 'user-agent: curl/8' http://localhost:8787/api/me
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
DIST=${1:-$HERE/dist}
WORK=$DIST/.build

: "${LLVM_PREFIX:?set LLVM_PREFIX to the official LLVM 23.1.1}"
WASM_LD=${WASM_LD:-$LLVM_PREFIX/bin/wasm-ld}
: "${WASI_BUILTINS:?set WASI_BUILTINS to libclang_rt.builtins.a for wasm32-unknown-wasip1}"
# spinel-llvm called its tools/mlir/spinel-mlirgen front; this repository has
# the native emitter it routed to, which takes the same argv.
MLIRGEN=${MLIRGEN:-${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin/spinel-fs-emit}
NM="$LLVM_PREFIX/bin/llvm-nm"
PROFILE=$ROOT/tools/freestanding/profiles/wasm32-worker.yaml

mkdir -p "$DIST" "$WORK/spinel"

# --- 1. the body: full Ruby, and the Workers scaffold around it ------------
# This also drops worker.mjs / wasi_shim.mjs / spinel_host.mjs into dist and
# writes an index.mjs + wrangler.toml, both of which we replace below.
"$ROOT/tools/wasm/spinel-wasm" "$HERE/app.rb" --emit-worker "$DIST" >/dev/null

# --- 2. the gatekeeper: freestanding ---------------------------------------
# `spinel/freestanding.rb` is the declaration surface; it is copied rather than
# vendored into the example so there is exactly one copy in the repo.
cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$WORK/spinel/"
cp "$HERE/kern.rb" "$WORK/kern.rb"
(cd "$WORK" && "$MLIRGEN" kern.rb --freestanding \
    --profile "$PROFILE" -o kern.o \
    --emit-header spinel_freestanding.h --emit-undef-tsv undef.tsv >/dev/null)

# The export list is READ OUT OF THE OBJECT: the freestanding_def declarations
# are the boundary, and a hand-written --export list could disagree with them.
EXPORTS=()
while read -r sym; do EXPORTS+=("--export=$sym"); done < <(
  "$NM" --defined-only --extern-only "$WORK/kern.o" | awk '{print $3}' | sort)
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    "$WORK/kern.o" "$WASI_BUILTINS" -o "$DIST/kern.wasm"

# --- 3. the router's view of the boundary ----------------------------------
# Generated from the generated header, never transcribed (E063 §8).
ruby "$ROOT/examples/tools/kern_sig.rb" "$WORK/spinel_freestanding.h" "$DIST/kern_sig.json" "kern_sig.json"

cp "$HERE/index.mjs" "$DIST/index.mjs"
cp "$WORK/spinel_freestanding.h" "$DIST/spinel_freestanding.h"

# --- 4. wrangler.toml ------------------------------------------------------
# Written here rather than left to the scaffold because this Worker imports TWO
# wasm modules and needs its own [vars].
cat > "$DIST/wrangler.toml" <<'TOML'
name = "spinel-gatekeeper"
main = "index.mjs"
compatibility_date = "2026-01-01"

# BOTH modules arrive as compiled WebAssembly.Modules, so compilation is once
# per isolate for each.  It matters more for kern.wasm than for app.wasm: at
# ~2 KB, compiling it per request would be most of what it costs.
[[rules]]
type = "CompiledWasm"
globs = ["**/*.wasm"]
fallthrough = false

[vars]
# --- the gatekeeper's policy.  All integers; the kernel has no other kind. ---
GATE_RATE_MT_S    = "5000"    # refill, milli-tokens per second (5 req/s)
GATE_BURST_MT     = "20000"   # cap, milli-tokens (20 requests of headroom)
GATE_COST_MT      = "1000"    # one request costs one token
GATE_BUCKETS      = "4"       # A/B arms: 0 = control, 1..3 = variants
GATE_BOT_THRESHOLD = "60"     # bot_score >= this -> 403
GATE_KERN_RESIDENT = "1"      # 0 = instantiate the 2 KB kernel per request

# --- the body ---------------------------------------------------------------
SPINEL_CGI_HEADERS = "1"      # app.rb emits Status:/Content-Type:

# Edge auth is OPT-IN and off by default (local dev).  Turn it on with
#   npx wrangler secret put SPINEL_AUTH_TOKEN     (or a .dev.vars line)
# and call with `Authorization: Bearer <token>`.  Note the stage order: the
# gatekeeper runs BEFORE this check, so a flood of bad tokens is rate limited
# without ever reaching the comparison.
# SPINEL_AUTH_TOKEN = "..."
TOML

# --- 5. what was built -----------------------------------------------------
gz() { gzip -9 -c "$1" | wc -c | tr -d ' '; }
printf 'built %s\n' "$DIST"
printf '  %-12s %8s B  (gzip %6s B)  freestanding gatekeeper, imports: %s\n' \
  kern.wasm "$(wc -c < "$DIST/kern.wasm" | tr -d " ")" "$(gz "$DIST/kern.wasm")" \
  "$(node -e 'const fs=require("fs");console.log(WebAssembly.Module.imports(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).map(i=>i.module+"."+i.name).join(",")||"(none)")' "$DIST/kern.wasm")"
printf '  %-12s %8s B  (gzip %6s B)  full Ruby body\n' \
  app.wasm "$(wc -c < "$DIST/app.wasm" | tr -d " ")" "$(gz "$DIST/app.wasm")"
printf '  ratio      %s x smaller (raw)\n' \
  "$(ruby -e 'printf("%.0f", Integer(ARGV[0], 10).to_f / Integer(ARGV[1], 10))' \
      "$(wc -c < "$DIST/app.wasm" | tr -d " ")" "$(wc -c < "$DIST/kern.wasm" | tr -d " ")")"
echo
echo "next: cd $DIST && npx wrangler dev --local"
