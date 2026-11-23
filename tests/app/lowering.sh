#!/bin/sh
#
# tests/app/lowering.sh -- decision 0014, Task 5: lowering.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/lowering.sh
#
# The application entries of tests/app/fixtures/lowering/body.rb (with the
# real tools/app/lib/spinel/net.rb prepended) are built by the kernel for the
# host and for thumbv8m, and checked:
#
#   1. the optimised IR: atomics exactly on the atomic closure -- the cross
#      entry buffer, and both parameters of a helper reached with one cross and
#      one private argument -- and none outside it; one declaration per extern;
#      the guards before an extern call return their status;
#   2. built for thumbv8m: the undefined set equals the declared externs, by
#      the gate with --extern; every cross access of the cross-only entry is
#      one LDRB or STRB and the object has no LDRD, STRD, LDM or STM; a literal
#      passed to an extern is in the object's own read-only data; the 0010
#      relocation rule passes with the externs named, and refuses without;
#   3. the ABI fixtures, native: a harness links the host objects with C
#      providers compiled against the generated extern header -- a literal
#      arrives as its bytes and length, a state buffer as its pointer and
#      constant count, each guard failure returns its status with no call,
#      `send(buf, 0)` constant and from state each return ARGUMENT with the
#      effects before the call kept, a constant-invalid send on an untaken path
#      runs to OK, and writes past a short buffer through put_str and put_dec
#      return BOUNDS with the canaries on both sides untouched; a provider that
#      drops a `_len` parameter fails to compile;
#   4. the final D1 probe: the union of the thumbv8m objects' undefined symbols,
#      less the declared externs, equals tests/app/fixtures/lowering/d1-helpers.txt;
#   5. controls: an i64 cross buffer is refused for thumbv8m and built for the
#      host; a cross buffer passed to an extern is refused by admission and
#      writes no object.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures/lowering"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
GATE="$ROOT/tools/core/core-artifact-gate"
RELOCS="$ROOT/tests/doom-core/object-relocs.rb"
RUBY="${RUBY:-ruby}"
die() { echo "lowering: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
BIN=$(dirname "$CC_BIN")
NM="${NM:-$BIN/llvm-nm}"; READOBJ="${READOBJ:-$BIN/llvm-readobj}"; DIS="$BIN/llvm-dis"; OBJDUMP="$BIN/llvm-objdump"
export NM READOBJ
TFLAGS="--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os"

W=$(mktemp -d "${TMPDIR:-/tmp}/app-lowering.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }

cat "$ROOT/tools/app/lib/spinel/net.rb" "$FIX/body.rb" > "$W/app.rb"
cp "$FIX"/*.contract "$W/"
EXTERNS="spc_board_adc_latest spc_channel_telemetry_put spc_log_write"
HOST_ENTRIES="tick send_zero send_n untaken oob_str oob_dec cross_only wide lit_str lit_dec fixdiv"
ARM_ENTRIES="tick send_n cross_only lit_str lit_dec fixdiv"

echo "lowering: building the entries for the host"
for e in $HOST_ENTRIES; do
  "$KERNEL" "$W/$e.contract" --root "$W" -o "$W/$e.o" --header "$W/$e.h" --emit-optimised-ir "$W/$e.bc" \
    --clang "$CC_BIN" --typedump "$READER" > "$W/$e.log" 2>&1 || die "$e did not build for the host; see $W/$e.log"
  "$DIS" "$W/$e.bc" -o "$W/$e.ll"
done
"$KERNEL" "$W/tick.contract" --root "$W" -o "$W/tick.x.o" --extern-header "$W/externs.h" \
  --clang "$CC_BIN" --typedump "$READER" > "$W/externs.log" 2>&1 || die "the extern header did not build"

echo "lowering: 1. the optimised IR"
atomics() { grep -cE '(load|store) atomic ' "$1"; }
ok "tick: three atomic accesses -- the cross store, and the helper's load and store" "$(atomics "$W/tick.ll")" 3
# Task 11: under --record-cross the recorder performs each cross access (a
# call in place of the atomic); without the flag nothing changes
"$KERNEL" "$W/tick.contract" --root "$W" -o "$W/tick.rec.o" --emit-optimised-ir "$W/tick.rec.bc" --record-cross \
  --clang "$CC_BIN" --typedump "$READER" > "$W/tick.rec.log" 2>&1 || die "tick did not build under --record-cross; see $W/tick.rec.log"
"$DIS" "$W/tick.rec.bc" -o "$W/tick.rec.ll"
ok "tick under --record-cross: the three cross accesses are calls to the recorder's hooks, no atomic remains, and the hooks are the object's undefined symbols" \
   "$(grep -cE 'call (i64|void) @spc_record_(load|store)' "$W/tick.rec.ll"):$(atomics "$W/tick.rec.ll"):$("$ROOT/tools/core/object-symbols" --undefined "$W/tick.rec.o" | cut -f2 | grep -c '^spc_record_' || true)" "3:0:2"
ok "control: without the flag the same entry keeps its three atomics and calls no hook (the production lowering is unchanged)" \
   "$(atomics "$W/tick.ll"):$(grep -c 'spc_record_' "$W/tick.ll" || true)" "3:0"
ok "tick: the helper's accesses are both monotonic at element alignment" \
   "$(grep -cE 'atomic i8, ptr %[0-9]+ monotonic, align 1|atomic i8 %[0-9]+, ptr %[0-9]+ monotonic, align 1' "$W/tick.ll")" 2
ok "tick: plain accesses remain outside the closure" "$(grep -cE '^\s+(store|%[0-9]+ = load) i(8|32)' "$W/tick.ll" | awk '{print ($1 > 0) ? "some" : "none"}')" some
ok "send_n: no atomics where nothing is cross" "$(atomics "$W/send_n.ll")" 0
ok "tick: one declaration per extern" "$(grep -c '^declare .*@spc_' "$W/tick.ll"):$(grep -E '^declare .*@spc_' "$W/tick.ll" | grep -oE 'spc_[a-z_]+' | sort -u | wc -l | tr -d ' ')" "3:3"
ok "send_n: the guards return ARGUMENT and BOUNDS before the call" \
   "$(grep -E 'ret i32 1$|phi i32 .*\[ 1, ' "$W/send_n.ll" | wc -l | awk '{print ($1 > 0)}'):$(grep -E 'ret i32 3$|phi i32 .*\[ 3, ' "$W/send_n.ll" | wc -l | awk '{print ($1 > 0)}')" "1:1"
ok "send_zero: a constant-false guard is an unconditional failure at that site, and the call is gone" \
   "$(grep -c 'call .*spc_channel_telemetry_put' "$W/send_zero.ll" || true):$(grep -E 'ret i32 1$|phi i32 .*\[ 1, ' "$W/send_zero.ll" | wc -l | awk '{print ($1 > 0)}')" "0:1"
ok "tick: the literal passed to the extern is a private constant" "$(grep -c 'private constant \[5 x i8\] c"tick' "$W/tick.ll")" 1

echo "lowering: 2. built for thumbv8m"
for e in $ARM_ENTRIES; do
  "$KERNEL" "$W/$e.contract" --root "$W" -o "$W/$e.arm.o" --layout ptr32-i64-32long \
    --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > "$W/$e.arm.log" 2>&1 || die "$e did not build for thumbv8m; see $W/$e.arm.log"
done
ok "tick: the gate passes with the three externs named" \
   "$(sh "$GATE" $(for s in $EXTERNS; do printf -- '--extern %s ' "$s"; done) "$W/tick.arm.o" spinel_core_tick > /dev/null 2>&1 && echo pass || echo fail)" pass
ok "control: the gate refuses tick with one extern unnamed" \
   "$(sh "$GATE" --extern spc_board_adc_latest --extern spc_log_write "$W/tick.arm.o" spinel_core_tick > "$W/g.out" 2>&1 && echo pass || grep -c 'depends on \[spc_channel_telemetry_put\]' "$W/g.out")" 1
"$OBJDUMP" -d "$W/cross_only.arm.o" > "$W/cross_only.dis"
ok "cross_only: eight LDRB and eight STRB, one per element" \
   "$(grep -cE '^\s+[0-9a-f]+:.*\sldrb\s' "$W/cross_only.dis"):$(grep -cE '^\s+[0-9a-f]+:.*\sstrb\s' "$W/cross_only.dis")" "8:8"
ok "cross_only: no LDRD, STRD, LDM or STM" \
   "$(grep -cE '^\s+[0-9a-f]+:.*\s(ldrd|strd|ldm|stm|ldmia|stmia|ldmdb|stmdb)\s' "$W/cross_only.dis")" 0
ok "tick: the extern's literal is in the object's own read-only data" \
   "$("$OBJDUMP" -s -j .rodata "$W/tick.arm.o" | grep -c ' 7469636b ')" 1
ok "the 0010 relocation rule passes with the externs named" \
   "$("$RUBY" "$RELOCS" $(for s in $EXTERNS $(cat "$FIX/d1-helpers.txt"); do printf -- '--extern %s ' "$s"; done) "$BIN" "$W/tick.arm.o" "$W/cross_only.arm.o" "$W/lit_dec.arm.o" 2>&1 | grep -c ' ok$')" 3
ok "control: the relocation rule refuses the extern branch when it is not named" \
   "$("$RUBY" "$RELOCS" "$BIN" "$W/tick.arm.o" 2>&1 | grep -c 'refused R_ARM_THM_CALL to spc_')" 1

echo "lowering: 3. the ABI fixtures, native"
cp "$FIX/harness.c" "$FIX/bad_provider.c" "$W/"
if "$CC_BIN" -O2 -Wall -I"$W" "$W/harness.c" "$W/tick.o" "$W/send_zero.o" "$W/send_n.o" "$W/untaken.o" \
     "$W/oob_str.o" "$W/oob_dec.o" -o "$W/harness" > "$W/harness.build" 2>&1; then
  "$W/harness" > "$W/harness.out" 2>&1 && hrc=0 || hrc=$?
  grep -E '^  (ok|FAIL)' "$W/harness.out" || true
  hp=$(grep -c '^  ok ' "$W/harness.out" || true); hf=$(grep -c '^  FAIL ' "$W/harness.out" || true)
  pass=$((pass + hp)); fail=$((fail + hf))
  ok "the harness ran to its summary" "$hrc:$(tail -1 "$W/harness.out")" "0:harness: 0 failed"
else
  ok "the harness builds" "$(head -1 "$W/harness.build")" built
fi
ok "control: a provider without the _len parameter does not compile against the extern header" \
   "$("$CC_BIN" -c -I"$W" "$W/bad_provider.c" -o "$W/bad.o" > "$W/bad.build" 2>&1 && echo compiled || grep -c 'conflicting types' "$W/bad.build")" 1

echo "lowering: 4. the final D1 probe"
: > "$W/undef.txt"
for e in $ARM_ENTRIES; do "$NM" -u "$W/$e.arm.o" | awk '{print $NF}' | sed "s/^/$e /" >> "$W/undef.txt"; done
echo "  undefined symbols, verbatim (entry symbol):"; sed 's/^/    /' "$W/undef.txt"
helpers=$(awk '{print $2}' "$W/undef.txt" | grep -v '^spc_' | LC_ALL=C sort -u | tr '\n' ' ')
ok "the union less the externs is the recorded D1 list" "${helpers:-none}" "$(LC_ALL=C sort "$FIX/d1-helpers.txt" | tr '\n' ' ')"
ok "every recorded helper is referenced by some object" \
   "$(while read -r h; do grep -q " $h$" "$W/undef.txt" || echo "$h"; done < "$FIX/d1-helpers.txt" | wc -l | tr -d ' ')" 0

echo "lowering: 5. controls"
"$KERNEL" "$W/wide.contract" --root "$W" -o "$W/wide.arm.o" --layout ptr32-i64-32long \
  --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > "$W/wide.arm.log" 2>&1 && rc=0 || rc=$?
ok "an i64 cross buffer is refused for thumbv8m, by name" "$rc:$(grep -c 'cross-i64' "$W/wide.arm.log"):$([ -e "$W/wide.arm.o" ] && echo object || echo none)" "1:1:none"
ok "and built for the host" "$([ -s "$W/wide.o" ] && echo built || echo none)" built
mkdir -p "$W/x"; cp "$ROOT/tests/app/fixtures/contract/elig/cross-to-extern.rb" "$ROOT/tests/app/fixtures/contract/elig/cross-to-extern.contract" "$W/x/"
"$KERNEL" "$W/x/cross-to-extern.contract" --root "$W/x" -o "$W/x/c.o" --clang "$CC_BIN" --typedump "$READER" > "$W/x/c.log" 2>&1 && rc=0 || rc=$?
ok "a cross buffer passed to an extern is refused by admission and not lowered" \
   "$rc:$(grep -c 'cross-to-extern' "$W/x/c.log"):$([ -e "$W/x/c.o" ] && echo object || echo none)" "1:1:none"

echo
echo "lowering: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ] || exit 1
