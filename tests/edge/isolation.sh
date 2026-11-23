#!/usr/bin/env bash
#
# tests/edge/isolation.sh -- request isolation through the pooled WASI shim.
#
#   bash tests/edge/isolation.sh
#
# Builds tests/edge/isolation/app.rb with tools/wasm/spinel-wasm (the same
# environment as tests/edge/run.sh: LLVM_PREFIX, WASI_SYSROOT, WASI_BUILTINS)
# and runs tests/edge/isolation.mjs, which sends two different requests in a
# row through one isolate and fails if the second carries anything of the
# first. It does so for the ordinary build (a new instance per request) and
# for the arena build (one instance, written back before each request;
# decision 0039). Exit 0 on success, 1 on a failure, 2 when node is missing.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
command -v node >/dev/null 2>&1 || { echo "---- isolation: SKIP (no node)"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/edge-isolation.XXXXXX")
trap 'rm -rf "$W"' EXIT
# Twice: the ordinary build, which gets a new instance per request, and the
# arena build, whose one instance is written back before each request
# (decision 0039).
rc=0
for kind in ordinary arena; do
  flags=(); more=()
  [ "$kind" = arena ] && { flags=(--request-arena); more=(--reused); }
  echo "== $kind build"
  if ! BUILD_DIR="$W/build" "$REPO/tools/wasm/spinel-wasm" "$HERE/isolation/app.rb" ${flags[@]+"${flags[@]}"} \
       -o "$W/$kind.wasm" > "$W/$kind.log" 2>&1; then
    tail -5 "$W/$kind.log"
    echo "---- isolation: FAIL (the test program does not build: $kind)"
    exit 1
  fi
  node --experimental-wasm-exnref "$HERE/isolation.mjs" "$W/$kind.wasm" ${more[@]+"${more[@]}"} > "$W/$kind.txt" 2>&1 || rc=1
  grep -v 'ExperimentalWarning\|--trace-warnings' "$W/$kind.txt"
done
exit "$rc"
