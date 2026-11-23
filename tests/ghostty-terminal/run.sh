#!/bin/sh
#
# tests/ghostty-terminal/run.sh -- spinel-wasm's --link, and the terminal example.
#
#   LLVM_PREFIX, WASI_SYSROOT, WASI_BUILTINS   as tools/wasm/spinel-wasm reads them
#   GHOSTTY_DIR         a built Ghostty checkout (examples/ghostty-terminal/README.md)
#   PLAYWRIGHT_DIR      a directory where node can require playwright
#   PLAYWRIGHT_BROWSERS_PATH   where its Chromium is
#
# 1. --link: a Ruby program calls a C function from a wasm object given with
#    --link and prints its answer; without --link the same build does not
#    produce that answer (the control); --link with no file is refused.
# 2. the terminal: the page builds, and gpu-check.mjs types into it in headless
#    Chromium and reads drawn pixels against the terminal's own contract.
# 3. the shell connection: bridge.rb, compiled by Spinel, serves the page and
#    connects it to /bin/bash; remote-check.mjs runs commands through it and
#    checks the bridge's refusals.
#
# Exit 0 when everything passed, 1 on any failure, 2 when nothing failed but
# something was skipped.
set -u
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
T="$REPO/tests/ghostty-terminal"
SW="$REPO/tools/wasm/spinel-wasm"
pass=0; fail=0; skip=0
W=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-terminal.XXXXXX")
trap 'rm -rf "$W"' EXIT
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
skp() { skip=$((skip + 1)); echo "SKIP  $1"; }

if [ -z "${LLVM_PREFIX:-}" ] || [ -z "${WASI_SYSROOT:-}" ]; then
  echo "---- ghostty-terminal: SKIP (LLVM_PREFIX and WASI_SYSROOT are required)"; exit 2
fi
[ -x "$REPO/vendor/spinel/bin/spinel" ] || { echo "---- ghostty-terminal: SKIP (build vendor/spinel first)"; exit 2; }

echo "== 1. --link"
"$LLVM_PREFIX/bin/clang" --target=wasm32-wasip1 --sysroot="$WASI_SYSROOT" -O2 -c "$T/link/add.c" -o "$W/add.o" ||
  bad "add.c compiles for wasm"
if "$SW" "$T/link/main.rb" -o "$W/linked.wasm" --link "$W/add.o" >"$W/l.log" 2>&1 &&
   [ "$(node "$T/link/run.mjs" "$W/linked.wasm" 2>"$W/n.log")" = 42 ]; then
  ok "a function from a --link object answers"
else bad "the --link program"; sed 's/^/      /' "$W/l.log" "$W/n.log"; fi
if "$SW" "$T/link/main.rb" -o "$W/unlinked.wasm" >"$W/l.log" 2>&1 &&
   [ "$(node "$T/link/run.mjs" "$W/unlinked.wasm" 2>/dev/null)" = 42 ]; then
  bad "the same build answered without --link (the control)"
else ok "without --link the build does not answer (the control)"; fi
"$SW" "$T/link/main.rb" -o "$W/x.wasm" --link >"$W/l.log" 2>&1; rc=$?
if [ "$rc" != 0 ] && grep -q -- '--link needs a file' "$W/l.log"; then ok "--link with no file is refused"
else bad "--link with no file: exit $rc"; sed 's/^/      /' "$W/l.log"; fi

echo "== 2. the terminal"
if [ -z "${GHOSTTY_DIR:-}" ] || [ ! -f "${GHOSTTY_DIR:-}/zig-out/lib/libghostty-vt.a" ]; then
  skp "GHOSTTY_DIR does not name a built Ghostty checkout"
elif [ -z "${PLAYWRIGHT_DIR:-}" ]; then
  skp "PLAYWRIGHT_DIR is not set"
elif ! sh "$REPO/examples/ghostty-terminal/build.sh" "$W/out" >"$W/b.log" 2>&1; then
  bad "the page builds"; sed 's/^/      /' "$W/b.log"
else
  ok "the page builds"
  node "$T/gpu-check.mjs" "$W/out/web" "$W/out" >"$W/g.log" 2>&1
  rc=$?
  n=$(grep -c '^ok ' "$W/g.log")
  if [ "$rc" = 0 ] && grep -q '^bad = 0$' "$W/g.log" && [ "$n" = 22 ]; then ok "the 22 drawn-pixel checks hold"
  else bad "the drawn-pixel checks (exit $rc, $n ok)"; grep -v '^ok ' "$W/g.log" | sed 's/^/      /'; fi
  echo "== 3. the shell connection"
  node "$T/remote-check.mjs" "$W/out/bridge" "$W/out/web" >"$W/r.log" 2>&1
  rc=$?
  n=$(grep -c '^ok ' "$W/r.log")
  if [ "$rc" = 0 ] && grep -q '^bad = 0$' "$W/r.log" && [ "$n" = 35 ]; then ok "the 35 shell-connection checks hold"
  else bad "the shell-connection checks (exit $rc, $n ok)"; grep -v '^ok ' "$W/r.log" | sed 's/^/      /'; fi
fi

echo "---- ghostty-terminal: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
[ "$skip" = 0 ] || exit 2
