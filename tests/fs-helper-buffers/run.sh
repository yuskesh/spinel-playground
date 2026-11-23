#!/bin/sh
#
# tests/fs-helper-buffers/run.sh -- decision 0044: a freestanding helper
# indexes a buffer its caller lent it (the address and the length its caller
# holds), with the lender's mode and its own range check.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/fs-helper-buffers/run.sh
#
# 1. A 64-bit body: k.rb is compiled by spinel-fs-emit for the x86_64 Linux
#    host profile, linked with drive.c, and must print expect.txt.
# 2. A 32-bit body: k.rb for the wasm32 profile, linked with wasm-ld and run
#    under node by run.mjs, must print the same expect.txt.
# 3. The embedded profiles: k.rb and the decision's two probes (probe/)
#    compile for the Cortex-M33 and RV32 Zephyr profiles, and the probes for
#    the two above. (Running those on QEMU or a board is not done here.)
# 4. The prototypes: an entry's read-only buffer is still `const`, and an
#    entry that is also called from another entry keeps its own prototype.
# 5. U1 in the IR (wasm32): `uput`, reached only from an entry declared
#    `bounds: :unchecked`, has no trap-4 call; `mput`, reached from a checked
#    entry as well, has one; so does every other helper that indexes, `leaf`
#    too, which a checked entry reaches only through an unchecked one, and
#    `bridge2`, an unchecked entry that a checked entry calls.
# 6. Refusals, each with the words its row names (refuse/; extern and view
#    on decision E083's wasm32 profile, which declares a platform extern).
#    A lent buffer keeps every mode that reaches it, through any chain: no
#    store through one lent from :in, no read (or walk) through one lent
#    from :out, and the refusal names the chain.
# 7. Controls, each with an input it plants: a changed expected line is
#    reported as a difference, and a refusal checked against another row's
#    words fails.
#
# The expected values were written by hand from Ruby's rules; no other
# implementation is run.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp, and LLVM_PREFIX (or CLANG) for
# the official LLVM 23.1.1. Part 1 runs on x86_64 Linux only; part 2 needs
# wasm-ld (WASM_LD, default beside the compiler) and node (NODE). Where either
# cannot run, it is a named skip.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE=$ROOT/tests/fs-helper-buffers
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
EMIT=$BIN/spinel-fs-emit
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
PROFILES=$ROOT/tools/freestanding/profiles
E083=$ROOT/tests/freestanding/e083/wasm32-worker-e083.yaml

die() { echo "fs-helper-buffers: $*" >&2; exit 2; }
[ -x "$EMIT" ] || die "no spinel-fs-emit at $EMIT (tools/mlir/native/build.sh)"
[ -x "$READER" ] || die "no reader at $READER (tools/contract/build.sh)"
[ -f "$E083" ] || die "no E083 profile at $E083"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
LLVM_BIN=$(dirname "$CC_BIN")
WASM_LD_BIN=${WASM_LD:-$LLVM_BIN/wasm-ld}
NM_BIN=${NM:-$LLVM_BIN/llvm-nm}
NODE_BIN=${NODE:-node}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$EMIT"
source_stamp reader "$READER"

T=$(mktemp -d "${TMPDIR:-/tmp}/fs-helper-buffers.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1"; skip=$((skip + 1)); }
# same EXPECTED GOT: `same` when the files are equal, else the first difference
same() { if cmp -s "$1" "$2"; then echo same; else diff "$1" "$2" | sed -n 2p; fi; }

mkdir -p "$T/fs/spinel"
cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$T/fs/spinel/"
# emit FILE PROFILE-PATH [EXTRA...]: compiles a copy as $T/fs/k.rb; prints the
# exit status, stderr in $T/fs/err
emit() {
  src=$1; prof=$2; shift 2
  cp "$src" "$T/fs/k.rb" || return 2
  (cd "$T/fs" && "$EMIT" k.rb --freestanding --profile "$prof" \
     --typedump "$READER" -o k.o --emit-header k.h "$@") > "$T/fs/err" 2>&1
  echo $?
}
# emit_ir PROFILE-PATH: k.rb with the LLVM IR beside the object, as k.ll
emit_ir() {
  (cd "$T/fs" && "$EMIT" --profile "$1" --source k.rb --typedump "$READER" \
     -o k.o --emit-llvm k.ll --emit-header k.h) > "$T/fs/err" 2>&1
  echo $?
}

echo "== 1. a 64-bit body (x86_64 host profile) =="
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  ok "k.rb compiles" "$(emit "$HERE/k.rb" "$PROFILES/x86_64-linux-host.yaml")" 0
  if "$CC_BIN" -I"$T/fs" "$HERE/drive.c" "$T/fs/k.o" -o "$T/fs/drive" > "$T/fs/link.err" 2>&1; then
    "$T/fs/drive" > "$T/out64" 2>&1
    ok "the calls give expect.txt" "$(same "$HERE/expect.txt" "$T/out64")" same
  else
    echo "  FAIL k.rb does not link with drive.c"; sed 's/^/      /' "$T/fs/link.err" | head -4
    fail=$((fail + 1))
  fi
else
  skipped "the 64-bit values: the x86_64 Linux host profile does not run on $(uname -s) $(uname -m)"
fi

echo "== 2. a 32-bit body (wasm32 profile, under node) =="
if ! "$WASM_LD_BIN" --version > /dev/null 2>&1; then
  skipped "the 32-bit values: wasm-ld at $WASM_LD_BIN does not run"
elif ! "$NODE_BIN" --version > /dev/null 2>&1; then
  skipped "the 32-bit values: no node ($NODE_BIN)"
else
  ok "k.rb compiles" "$(emit "$HERE/k.rb" "$PROFILES/wasm32-worker.yaml")" 0
  exports=$("$NM_BIN" --defined-only --extern-only "$T/fs/k.o" 2>/dev/null |
            awk '{printf " --export=%s", $3}')
  # shellcheck disable=SC2086 # one word per export
  if [ -n "$exports" ] &&
     "$WASM_LD_BIN" --no-entry --allow-undefined $exports "$T/fs/k.o" \
       -o "$T/fs/k.wasm" > "$T/fs/link.err" 2>&1; then
    "$NODE_BIN" "$HERE/run.mjs" "$T/fs/k.wasm" > "$T/out32" 2>&1
    ok "the calls give expect.txt" "$(same "$HERE/expect.txt" "$T/out32")" same
  else
    echo "  FAIL k.rb does not link with wasm-ld"; sed 's/^/      /' "$T/fs/link.err" | head -4
    fail=$((fail + 1))
  fi
fi

echo "== 3. the embedded profiles, and the decision's probes =="
for prof in cortex-m33-zephyr riscv32-zephyr; do
  ok "k.rb compiles for $prof" "$(emit "$HERE/k.rb" "$PROFILES/$prof.yaml")" 0
done
for prof in x86_64-linux-host wasm32-worker cortex-m33-zephyr riscv32-zephyr; do
  for p in m1_helper_buf m1b_helper_decl; do
    ok "probe $p compiles for $prof" "$(emit "$HERE/probe/$p.rb" "$PROFILES/$prof.yaml")" 0
  done
done

echo "== 4. the prototypes (wasm32) =="
emit "$HERE/k.rb" "$PROFILES/wasm32-worker.yaml" > /dev/null
ok "sum_in's :in buffer is const" \
  "$(grep -c '^int32_t spinel_sum_in(const int32_t \*, int32_t);$' "$T/fs/k.h")" 1
ok "setk, also called from via_entry, keeps its prototype" \
  "$(grep -c '^int32_t spinel_setk(int32_t \*, int32_t, int32_t);$' "$T/fs/k.h")" 1
ok "no helper has a prototype" \
  "$(grep -c -E 'spinel_(put|inner|outer|bump|get|walk|uput|mput)\(' "$T/fs/k.h")" 0

echo "== 5. U1 in the IR (wasm32) =="
cp "$HERE/k.rb" "$T/fs/k.rb"
ok "k.rb emits its IR" "$(emit_ir "$PROFILES/wasm32-worker.yaml")" 0
# traps4 FN: the trap-4 calls in the body of @sp_FN
traps4() {
  awk -v f="@sp_$1(" 'index($0, "define ") == 1 { in_fn = index($0, f) > 0 }
       in_fn && /call void @spinel_trap\(i32 4,/ { n++ }
       END { print n + 0 }' "$T/fs/k.ll"
}
ok "uput (unchecked entry only) has no range check" "$(traps4 uput)" 0
ok "mput (an unchecked and a checked entry) has one" "$(traps4 mput)" 1
# An unchecked entry no checked entry calls keeps its own accesses unchecked.
ok "unchecked_put (an unchecked entry nothing checked calls) has none" "$(traps4 unchecked_put)" 0
# leaf: reached from the unchecked entry bridge, and through it from the
# checked entry chain (review finding 2).
for f in put inner bump get leaf bridge2; do
  ok "$f checks its lent buffer" "$([ "$(traps4 "$f")" -ge 1 ] && echo yes || echo no)" yes
done
# A lent buffer is two arguments, the address and the length (L1).
ok "put takes (ptr, i32, i32, double)" \
  "$(grep -c '^define internal i32 @sp_put(ptr %0, i32 %1, i32 %2, double %3)' "$T/fs/k.ll")" 1

echo "== 6. refusals =="
# refused NAME WORDS [PROFILE-PATH]: the exit status, then whether the words
# are on the `spinel-mlirgen: unsupported:` line
refused() {
  rc=$(emit "$HERE/refuse/$1.rb" "${3:-$PROFILES/wasm32-worker.yaml}")
  printf '%s|%s' "$([ "$rc" != 0 ] && echo refused || echo "exit $rc")" \
    "$(grep -F "spinel-mlirgen: unsupported: " "$T/fs/err" | grep -cF "$2")"
}
while IFS='|' read -r name words; do
  case $name in ''|\#*) continue ;; esac
  ok "$name" "$(refused "$name" "$words")" "refused|1"
done <<'EOF'
in_store|'clear': stores into `b` (line 4), which is lent `src`, an `:in` buffer of 'k', lent by the call at line 9 in 'k'; a lent buffer keeps its mode
two_elems|'half' parameter 0 'b' is lent an :f32 buffer by the call at line 10 in 'k' and an :f64 buffer by the call at line 11 in 'k'; a lent buffer has one element type
in_entry|argument 0 of 'g' at line 10 in 'k' is the buffer `src`, which is read-only (:in) here (`src`, an `:in` buffer of 'k'), and 'g' declares [:i32_buf, :inout] there
out_read|'peek': reads `b` (line 4), which is lent `out`, an `:out` buffer of 'k', lent by the call at line 11 in 'k', lent by the call at line 7 in 'relay'; a lent buffer keeps its mode
out_each|'total': reads `b` (line 5), which is lent `out`, an `:out` buffer of 'k', lent by the call at line 12 in 'k'
out_entry|argument 0 of 'g' at line 8 in 'pass' is the buffer `b`, which is write-only (:out) here (`out`, an `:out` buffer of 'k', lent by the call at line 12 in 'k'), and 'g' declares [:i32_buf, :in] there
out_entry_direct|argument 0 of 'read_entry' at line 9 in 'call_out' is the buffer `b`, which is write-only (:out) here (`b`, an `:out` buffer of 'call_out'), and 'read_entry' declares [:i32_buf, :in] there
local|'keep': the value assigned to `x` is a buffer; a buffer can be indexed and passed to a helper that takes it, and is not a value
elem|'k' parameter 0 'out' is a buffer of more than one element type
ret|'back' returns an Integer buffer
num_entry|'g' parameter 2 'x' is poly
EOF
ok "extern" "$(refused extern 'passes `w`, a buffer lent to this helper; decision 0044 lets a helper index a lent buffer and lend it on to another helper, not pass it to a platform extern' "$E083")" "refused|1"
ok "view" "$(refused view 'takes a view of `w`, a buffer lent to this helper' "$E083")" "refused|1"
ok "no refusal calls a buffer a boolean" \
  "$(for f in "$HERE"/refuse/*.rb; do emit "$f" "$E083" > /dev/null; cat "$T/fs/err"; done |
     grep -c 'is a boolean')" 0

echo "== 7. controls =="
# a. One expected line changed is reported, so the comparison can fail.
got=""
[ -f "$T/out32" ] && got=$T/out32
[ -f "$T/out64" ] && got=$T/out64
if [ -n "$got" ]; then
  sed 's/^sum_in 12$/sum_in 13/' "$HERE/expect.txt" > "$T/planted.txt"
  ok "a changed expected line is a difference" "$(same "$T/planted.txt" "$got")" "< sum_in 13"
else
  skipped "control a: neither part 1 nor part 2 ran"
fi
# b. A refusal checked against another row's words does not pass.
ok "in_store is not refused as two element types" \
  "$(refused in_store 'a lent buffer has one element type')" "refused|0"

echo "fs-helper-buffers: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
