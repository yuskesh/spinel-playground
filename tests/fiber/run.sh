#!/usr/bin/env bash
#
# tests/fiber/run.sh -- the stackless Fiber and Enumerator.new of decision
# 0035, stages 1 and 3, on the hosted WASM route (tools/wasm/spinel-wasm).
#
#   bash tests/fiber/run.sh
#
# Needs what spinel-wasm needs (LLVM_PREFIX, WASI_SYSROOT, WASI_BUILTINS, a
# Ruby that can require "prism"), plus node and wasmtime (WASMTIME, default
# `wasmtime` on PATH).
#
#   1. accept/*.rb: each is built once through spinel-wasm and run under node
#      (--experimental-wasm-exnref) and wasmtime (-W exceptions=y). Its stdout
#      must equal accept/NAME.out, written by hand from Ruby's semantics. The
#      programs cover values in both directions, nested and recursive yielding
#      methods, every loop the rewrite lowers, break/next/early return, alive?,
#      FiberError on a finished fiber and at the root, an exception crossing
#      resume, require_relative from a rewritten entry file, fibers made by
#      one site several times in one activation, and Enumerator.new with
#      next/peek/rewind, StopIteration, loop, and internal iteration that
#      breaks out of an endless one.
#   2. reject/*.rb in reject.tsv: the build must fail, write no module, and
#      print `FILE:LINE:COL: spinel-fiber: ...` containing the listed text.
#   3. reject/required.rb: Fiber.new in a required file is not rewritten; the
#      driver's own symbol scan must refuse it and name decision 0035.
#   4. typed/: forms that need spinel-typedump's receiver types: `each` over
#      an Array or Range variable, and yielding instance methods called
#      through a typed local, self or an implicit receiver. With the reader
#      (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump), each
#      typed/NAME.rb with a NAME.out must print it on every runner, and each
#      row of typed/reject.tsv must be refused as listed; without the reader
#      that part is skipped by name. Without a reader, each_var.rb and
#      methods.rb must be refused naming the missing reader.
#
# Exit 0 when everything passed, 1 on any failure, 2 when a runner is missing.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
FW=$(mktemp -d "${TMPDIR:-/tmp}/fiber.XXXXXX")
DRV="$REPO/tools/wasm/spinel-wasm"
WASMTIME=${WASMTIME:-wasmtime}
: "${LLVM_PREFIX:?set LLVM_PREFIX}" "${WASI_SYSROOT:?set WASI_SYSROOT}" "${WASI_BUILTINS:?set WASI_BUILTINS}"
trap 'rm -rf "$FW"' EXIT

pass=0; fail=0; skip=0
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass + 1))
  else echo "FAIL  $1"; echo "      got:  $(printf '%s' "$2" | head -c 400 | tr '\n' '|')"
       echo "      want: $(printf '%s' "$3" | head -c 400 | tr '\n' '|')"; fail=$((fail + 1)); fi
}
build() {  # rb wasm: 0 when it builds; the log is wasm.log
  BUILD_DIR="$FW/build" "$DRV" "$1" -o "$2" > "$2.log" 2>&1
}
RUNNERS=()
if command -v node >/dev/null 2>&1; then RUNNERS+=(node); else echo "SKIP  node runner (no node)"; skip=$((skip + 1)); fi
if command -v "$WASMTIME" >/dev/null 2>&1; then RUNNERS+=(wasmtime); else echo "SKIP  wasmtime runner (no $WASMTIME)"; skip=$((skip + 1)); fi
run_on() {  # runner wasm
  case $1 in
    node) node --experimental-wasm-exnref "$HERE/run.mjs" "$2" 2>/dev/null ;;
    wasmtime) "$WASMTIME" run -W exceptions=y "$2" 2>/dev/null ;;
  esac
}

echo "== accepted programs"
for rb in "$HERE"/accept/*.rb; do
  n=$(basename "$rb" .rb)
  [ -f "$HERE/accept/$n.out" ] || continue      # a helper that another file requires
  if ! build "$rb" "$FW/$n.wasm"; then
    ok "$n builds" "$(tail -5 "$FW/$n.wasm.log")" "(built)"
    continue
  fi
  for r in ${RUNNERS[@]+"${RUNNERS[@]}"}; do
    ok "$n on $r" "$(run_on "$r" "$FW/$n.wasm")" "$(cat "$HERE/accept/$n.out")"
  done
done

echo "== refusals"
while IFS="$(printf '\t')" read -r f pos text; do
  case $f in ''|'#'*) continue ;; esac
  out="$FW/rej-${f%.rb}.wasm"
  if build "$HERE/reject/$f" "$out"; then
    ok "$f is refused" "built" "refused"
    continue
  fi
  [ ! -e "$out" ] || { ok "$f writes no module" "written" "absent"; continue; }
  line=$(grep -F "$f:$pos: spinel-fiber: " "$out.log" | grep -F -- "$text" | head -1)
  ok "$f refused at $pos: $text" "${line:+found}" "found"
  [ -n "$line" ] || sed 's/^/      log: /' "$out.log" | head -5
done < "$HERE/reject.tsv"

out="$FW/rej-required.wasm"
if build "$HERE/reject/required.rb" "$out"; then
  ok "required.rb (Fiber in a required file) is refused" "built" "refused"
else
  ok "required.rb refused by the symbol scan, naming 0035" \
     "$(grep -c 'Fiber.new and Enumerator.new in the entry file are rewritten into stackless state machines (decision 0035)' "$out.log")" "1"
fi

echo "== typed receivers (spinel-typedump)"
refused_at() {  # name rb pos text [reader]: the build must fail with that refusal
  out="$FW/rej-$(printf '%s' "$1" | tr ' /' '__').wasm"
  if SPINEL_TYPEDUMP="${5:-$FW/no-reader}" build "$2" "$out"; then
    ok "$1 is refused" "built" "refused"
  else
    line=$(grep -F "$(basename "$2"):$3: spinel-fiber: " "$out.log" | grep -F -- "$4" | head -1)
    ok "$1 refused at $3: $4" "${line:+found}" "found"
    [ -n "$line" ] || sed 's/^/      log: /' "$out.log" | head -5
  fi
}
TD=${SPINEL_TYPEDUMP:-$REPO/tools/contract/build/spinel-typedump}
if [ -x "$TD" ]; then
  for rb in "$HERE"/typed/*.rb; do
    n=$(basename "$rb" .rb)
    [ -f "$HERE/typed/$n.out" ] || continue
    if ! SPINEL_TYPEDUMP="$TD" build "$rb" "$FW/typed-$n.wasm"; then
      ok "typed/$n builds with the reader" "$(tail -5 "$FW/typed-$n.wasm.log")" "(built)"
      continue
    fi
    for r in ${RUNNERS[@]+"${RUNNERS[@]}"}; do
      ok "typed/$n on $r" "$(run_on "$r" "$FW/typed-$n.wasm")" "$(cat "$HERE/typed/$n.out")"
    done
  done
  while IFS="$(printf '\t')" read -r f pos text; do
    case $f in ''|'#'*) continue ;; esac
    refused_at "typed/$f" "$HERE/typed/$f" "$pos" "$text" "$TD"
  done < "$HERE/typed/reject.tsv"
else
  echo "SKIP  typed receivers: no spinel-typedump at $TD (tools/contract/build.sh builds it)"; skip=$((skip + 1))
fi
# Without a reader the typed forms are refused, naming the missing reader.
refused_at "each_var without a reader" "$HERE/typed/each_var.rb" 5:3 "no type reader (spinel-typedump)"
refused_at "methods without a reader" "$HERE/typed/methods.rb" 33:7 "no type reader (spinel-typedump)"

echo "---- fiber: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
[ "$skip" -eq 0 ] || exit 2
exit 0
