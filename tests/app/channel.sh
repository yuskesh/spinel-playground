#!/bin/sh
# tests/app/channel.sh -- decision 0014 Task 8: channels, the UART transport
# and the byte helpers.
#
#   sh tests/app/channel.sh                                   # host and thumbv8m
#   ... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... sh tests/app/channel.sh   # plus QEMU
#
# What is checked, and against what:
#
#   1. The package renders from the templates: per channel a header, the
#      storage, and the put and the get each alone in a translation unit;
#      one transport; every unit compiles natively and for thumbv8m with
#      -Wall -Wextra -Werror, and a thumbv8m ring unit depends on nothing
#      but its own storage (no memcpy, no libc).
#   2. The ring, single-threaded on the host (fixtures/channel/ring_harness.c):
#      wraparound over 10 x depth, FIFO order without duplicates, a full
#      refusal that leaves the ring unchanged, 0 from an empty ring, and the
#      guards through the generated Ruby modules on the entries the kernel
#      built natively (ARGUMENT for n = 0, BOUNDS for n = 17, OK for 5).
#   3. The transport on the host (transport_harness.c): outbound frames,
#      inbound frames queued, the two drop reasons counted, a channel_full
#      drop only at occupancy == depth, framing errors apart. The mutated
#      transport (-DSPC_MUTATE_DROP_WITH_ROOM) is the plan's kept failing
#      input: the same harness fails on it.
#   4. The byte helpers: `fill` built natively by the kernel prints the same
#      32 bytes as CRuby on the fixed table (bytes.rb); with the Zephyr
#      environment the thumbv8m build runs under QEMU and prints them too.
#   5. The two-channel label fixture: the host-linked harness and the
#      thumbv8m link (the SDK's GNU ld; the official LLVM's lld is not used)
#      carry every spc_ring_<channel>_<op>_<copy|pub>_<begin|end> label once,
#      begin before end, inside the operation's function; linking a unit
#      twice is a link error naming the duplicate.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX), RUBY select the tools;
# ZEPHYR_SDK_INSTALL_DIR also names the GNU linker used for the thumbv8m
# link (arm-zephyr-eabi-ld under it), and with ZEPHYR_BASE and west the QEMU
# run happens; REQUIRE_ALL=1 makes those a failure instead of a skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures/channel"
BOARD="$ROOT/tests/app/fixtures/synthetic-board"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"
die() { echo "channel: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
export LLVM_PREFIX="${LLVM_PREFIX:-$(dirname "$(dirname "$CC_BIN")")}"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
"$RUBY" -e 'require "prism"; exit(RUBY_VERSION >= "3.1" ? 0 : 1)' >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' ($("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null)) is below 3.1 or cannot load prism, which the application tool needs."
TARGET=thumbv8m.main-none-eabi
TFLAGS="--target=$TARGET -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os"
QEMU_WAIT=${QEMU_WAIT:-30}

W=$(mktemp -d "${TMPDIR:-/tmp}/app-channel.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skips=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
# skipped WHAT N: N checks do not run; each counts as a skip (or a failure under REQUIRE_ALL=1)
skipped() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then echo "  FAIL $1 (REQUIRE_ALL=1; $2 checks)"; fail=$((fail + $2)); else echo "  skip $1 ($2 checks)"; skips=$((skips + $2)); fi; }

echo "channel: 1. the package renders and compiles"
"$RUBY" "$TOOL" package --app "$FIX/app.rb" --board "$BOARD/board.rb" --out "$W/pkg" > "$W/pkg.out" 2>&1 || die "package failed: $(cat "$W/pkg.out")"
CH="$W/pkg/channels"
ok "per channel a header, the storage, put and get in their own units, plus one transport" \
   "$(cd "$CH" && ls channel_* transport_uart.c | LC_ALL=C sort | tr '\n' ' ')" \
   "channel_commands.h channel_commands_get.c channel_commands_put.c channel_commands_ring.c channel_telemetry.h channel_telemetry_get.c channel_telemetry_put.c channel_telemetry_ring.c transport_uart.c "
ok "each operation unit defines exactly one function, and the label pairs of its own operation" \
   "$(grep -c '^int32_t spc_channel_' "$CH/channel_telemetry_put.c"):$(grep -c 'SPC_LABEL("spc_ring_telemetry_put_' "$CH/channel_telemetry_put.c"):$(grep -c 'spc_ring_telemetry_get_' "$CH/channel_telemetry_put.c" || true)" "1:4:0"
ok "the ring's copy is inlined into the labelled span and the unit names no libc function" \
   "$(grep -c 'always_inline' "$CH/channel_telemetry_put.c"):$(grep -c -e memcpy -e string.h "$CH/channel_telemetry_put.c" || true)" "1:0"
n=0; bad=
for f in "$CH"/channel_*.c "$CH"/transport_uart.c; do
  b=$(basename "$f" .c)
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O2 -DSPC_HOST -c "$f" -o "$W/$b.o" 2>"$W/$b.err" || bad="$bad $b(host)"
  # shellcheck disable=SC2086
  "$CC_BIN" $TFLAGS -std=c11 -Wall -Wextra -Werror -ffreestanding -DSPC_HOST -c "$f" -o "$W/$b.arm.o" 2>"$W/$b.arm.err" || bad="$bad $b(arm)"
  n=$((n + 1))
done
ok "every unit compiles natively and for thumbv8m with -Wall -Wextra -Werror ($n units)" "${bad:-clean}" clean
ok "a thumbv8m operation unit depends on the ring's storage and nothing else" \
   "$("$ROOT/tools/core/object-symbols" --undefined "$W/channel_telemetry_put.arm.o" | cut -f2 | LC_ALL=C sort | tr '\n' ' ')" \
   "spc_channel_telemetry_head spc_channel_telemetry_lens spc_channel_telemetry_slots spc_channel_telemetry_tail "
ok "the transport unit for thumbv8m depends on the channels' operations and storage only (host UART stubs named)" \
   "$("$ROOT/tools/core/object-symbols" --undefined "$W/transport_uart.arm.o" | cut -f2 | grep -vc '^spc_')" 0

# the host objects of the rings, by name (the .arm.o siblings share the glob)
HOST_RING="$W/channel_telemetry_put.o $W/channel_telemetry_get.o $W/channel_telemetry_ring.o $W/channel_commands_put.o $W/channel_commands_get.o $W/channel_commands_ring.o"
echo "channel: 2. the ring on the host, and the guards through the generated modules"
for e in report send_n poll fill; do
  "$KERNEL" "$W/pkg/pack/$e.contract" --root "$W/pkg/pack" -o "$W/$e.o" --clang "$CC_BIN" --typedump "$READER" > "$W/$e.log" 2>&1 \
    || die "$e did not build natively; see $W/$e.log"
done
"$CC_BIN" -O2 -Wall -I"$CH" "$FIX/ring_harness.c" $HOST_RING \
  "$W/report.o" "$W/send_n.o" "$W/poll.o" -o "$W/ring" > "$W/ring.build" 2>&1 || die "the ring harness did not link: $(cat "$W/ring.build")"
"$W/ring" > "$W/ring.out" 2>&1 && rc=0 || rc=$?
grep -E '^  (ok|FAIL)' "$W/ring.out"
ok "the ring harness ran to its summary" "$rc:$(tail -1 "$W/ring.out")" "0:harness: 0 failed"
ok "the ring harness made 21 checks" "$(grep -c '^  ok ' "$W/ring.out")" 21
# The package of an application without channels holds no C at all, and one
# with only an :out channel compiles its transport too (nothing to deliver).
"$RUBY" "$TOOL" package --app "$ROOT/tests/app/fixtures/apps/sched-overrun/app.rb" --board "$BOARD/board.rb" --out "$W/pkg0" > /dev/null 2>&1 || die "package of a channel-less app failed"
ok "an application without channels packages no channel C and no transport" "$(ls "$W/pkg0/channels" | grep -c '\.c$' || true)" 0
printf 'require "spinel/core"\nstate :f, :u8, 4\nchannel :out_only, :out, size: 4, depth: 2, uart: true\nevery_ms 5, :tick\ndef tick(f)\n  OutOnly.put(f, 1)\n  0\nend\n' > "$W/outonly.rb"
"$RUBY" "$TOOL" package --app "$W/outonly.rb" --board "$BOARD/board.rb" --out "$W/pkg1" > /dev/null 2>&1 || die "package of an out-only app failed"
"$CC_BIN" -std=c11 -Wall -Wextra -Werror -O2 -DSPC_HOST -c "$W/pkg1/channels/transport_uart.c" -o "$W/outonly.o" 2>"$W/outonly.err" && rc=0 || rc=$?
ok "the transport of an application with only an :out channel compiles under -Werror" "$rc:$(grep -c . "$W/outonly.err")" "0:0"

echo "channel: 3. the transport on the host"
"$CC_BIN" -O2 -Wall -I"$CH" "$FIX/transport_harness.c" "$W/transport_uart.o" $HOST_RING -o "$W/transport" > "$W/transport.build" 2>&1 \
  || die "the transport harness did not link: $(cat "$W/transport.build")"
"$W/transport" > "$W/transport.out" 2>&1 && rc=0 || rc=$?
grep -E '^  (ok|FAIL)' "$W/transport.out"
ok "the transport harness ran to its summary" "$rc:$(tail -1 "$W/transport.out")" "0:harness: 0 failed"
ok "the transport harness made 11 checks" "$(grep -c '^  ok ' "$W/transport.out")" 11
# The kept failing input, made from a copy of the generated transport, not
# from the product: the delivery to `commands` drops the second frame as
# channel_full while the ring has room.
sed 's|queued = spc_channel_commands_put(payload, n, n); /\* SPC_DELIVER commands \*/|queued = (sid == 2u) ? 0 : spc_channel_commands_put(payload, n, n);|' "$CH/transport_uart.c" > "$W/transport_mut.c"
cmp -s "$CH/transport_uart.c" "$W/transport_mut.c" && die "the mutation did not apply; the delivery line moved"
"$CC_BIN" -std=c11 -Wall -Wextra -Werror -O2 -DSPC_HOST -I"$CH" -c "$W/transport_mut.c" -o "$W/transport_mut.o" 2>"$W/mut.err" || die "the mutated transport did not compile: $(cat "$W/mut.err")"
"$CC_BIN" -O2 -Wall -I"$CH" "$FIX/transport_harness.c" "$W/transport_mut.o" $HOST_RING -o "$W/transport_mut" > /dev/null 2>&1 || die "the mutated transport harness did not link"
"$W/transport_mut" > "$W/transport_mut.out" 2>&1 && mrc=0 || mrc=$?
ok "control: a transport that drops a frame while the ring has room fails the harness (the kept failing input)" \
   "$mrc:$(grep -c '^  FAIL drop rule: a channel_full drop only at occupancy == depth' "$W/transport_mut.out")" "1:1"

echo "channel: 4. the byte helpers"
# The harness and the thumbv8m object are built either way. CRuby running
# bytes.rb is the reference for what they give, and the recorded bytes are
# CRuby's: those comparisons run only on the owner's instruction.
"$CC_BIN" -O2 -Wall "$FIX/bytes_harness.c" "$W/fill.o" -o "$W/bytes" > /dev/null 2>&1 || die "the bytes harness did not link"
# shellcheck disable=SC2086
"$KERNEL" "$W/pkg/pack/fill.contract" --root "$W/pkg/pack" -o "$W/fill.arm.o" --layout ptr32-i64-32long \
  --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > "$W/fill.arm.log" 2>&1 || die "fill did not build for thumbv8m; see $W/fill.arm.log"
if "$ROOT/tools/oracle/gate" tests/app/channel.sh bytes; then
  ref=$("$RUBY" "$FIX/bytes.rb")
  ok "CRuby's bytes on the fixed table are the recorded 32" "$ref" "ab3412feffffff2d31323334353034323934393637323936544147211c000000"
  ok "fill built natively by the kernel gives CRuby's bytes" "$("$W/bytes")" "$ref"
  if [ -n "${ZEPHYR_BASE:-}" ] && [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && command -v west > /dev/null 2>&1; then
    export ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR
    west build -p always -b mps2/an521/cpu0 "$FIX/qemu-probe" -d "$W/qemu" -- \
      -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" -DSPC_OBJ="$W/fill.arm.o" > "$W/qemu.log" 2>&1 || die "the QEMU probe did not build; see $W/qemu.log"
    rm -f "$W/qemu/qemu.pid"
    west build -d "$W/qemu" -t run > "$W/qemu.console" 2>&1 < /dev/null &
    runner=$!
    i=0
    while [ "$i" -lt "$QEMU_WAIT" ] && ! grep -q SPC_BYTES_DONE "$W/qemu.console"; do sleep 1; i=$((i + 1)); done
    # a process already gone makes kill return 1; under set -e that would end
    # the script here, before the comparison and everything after it
    if [ -f "$W/qemu/qemu.pid" ]; then kill "$(cat "$W/qemu/qemu.pid")" 2>/dev/null || true; fi
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    echo "  (the QEMU marker arrived after ${i}s)"
    ok "fill built for thumbv8m gives CRuby's bytes under QEMU" \
       "$(sed -n 's/.*SPC_BYTES status=\([0-9-]*\) \([0-9a-f]*\) SPC_BYTES_DONE.*/\1:\2/p' "$W/qemu.console" | head -1)" "0:$ref"
  else
    skipped "fill built for thumbv8m under QEMU (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH are needed)" 1
  fi
fi

echo "channel: 5. the two-channel label fixture"
# the channels, from the package itself, not typed here
CHANNELS=$(cd "$CH" && ls channel_*.h | sed 's/^channel_//; s/\.h$//' | LC_ALL=C sort | tr '\n' ' ')
ok "the package declares the two channels" "$CHANNELS" "commands telemetry "
CHARGS=$(for c in $CHANNELS; do printf -- '--channel %s ' "$c"; done)
# shellcheck disable=SC2086
ok "the host-linked harness carries every label once, copy before publication, inside its function" \
   "$("$RUBY" "$TOOL" labels --object "$W/ring" $CHARGS > "$W/labels.host" 2>&1 && echo placed || cat "$W/labels.host")" placed
ok "control: the label check refuses a channel the image does not carry" \
   "$("$RUBY" "$TOOL" labels --object "$W/ring" --channel telemetry --channel nosuch > "$W/labels.bad" 2>&1 && echo placed || grep -c 'spc_channel_nosuch_put is defined 0 time' "$W/labels.bad")" 1
ok "control: a missing image is a refusal with the tool's prefix, not a backtrace" \
   "$("$RUBY" "$TOOL" labels --object "$W/nowhere" --channel telemetry > "$W/labels.none" 2>&1 && echo placed || grep -c '^spinel-core-app: labels: no such image' "$W/labels.none")" 1
# The property the labels pin: the copy ends before the publication begins.
# A copy of telemetry's put with its publication moved above its copy links
# and runs (single-threaded, nothing can tell) and the label check refuses it.
"$RUBY" -e '
  s = File.read(ARGV[0])
  pub = s[/\tSPC_LABEL\("spc_ring_telemetry_put_pub_begin"\);\n.*?\tSPC_LABEL\("spc_ring_telemetry_put_pub_end"\);\n/m] or abort "no publication block"
  s = s.sub(pub, "")
  s = s.sub("\tSPC_LABEL(\"spc_ring_telemetry_put_copy_begin\");\n", pub + "\tSPC_LABEL(\"spc_ring_telemetry_put_copy_begin\");\n")
  File.write(ARGV[1], s)' "$CH/channel_telemetry_put.c" "$W/put_swapped.c"
"$CC_BIN" -std=c11 -O2 -DSPC_HOST -I"$CH" -c "$W/put_swapped.c" -o "$W/put_swapped.o" || die "the swapped put did not compile"
"$CC_BIN" -O2 -Wall -I"$CH" "$FIX/ring_harness.c" "$W/put_swapped.o" "$W/channel_telemetry_get.o" "$W/channel_telemetry_ring.o" \
  "$W/channel_commands_put.o" "$W/channel_commands_get.o" "$W/channel_commands_ring.o" "$W/report.o" "$W/send_n.o" "$W/poll.o" -o "$W/ring_swapped" > /dev/null 2>&1 || die "the swapped harness did not link"
"$W/ring_swapped" > "$W/ring_swapped.out" 2>&1 && src=0 || src=$?
# shellcheck disable=SC2086
ok "control: a put that publishes before it copies passes the single-threaded harness and is refused by the label check" \
   "$src:$("$RUBY" "$TOOL" labels --object "$W/ring_swapped" $CHARGS > "$W/labels.swapped" 2>&1 && echo placed || grep -c 'does not end before the publication span begins' "$W/labels.swapped")" "0:1"
LD=
[ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && LD=$(find "$ZEPHYR_SDK_INSTALL_DIR" -name arm-zephyr-eabi-ld -type f 2>/dev/null | head -1)
if [ -n "$LD" ] && [ -x "$LD" ]; then
  ARM_RING="$W/channel_telemetry_put.arm.o $W/channel_telemetry_get.arm.o $W/channel_telemetry_ring.arm.o $W/channel_commands_put.arm.o $W/channel_commands_get.arm.o $W/channel_commands_ring.arm.o"
  for e in report send_n poll; do
    # shellcheck disable=SC2086
    "$KERNEL" "$W/pkg/pack/$e.contract" --root "$W/pkg/pack" -o "$W/$e.arm.o" --layout ptr32-i64-32long \
      --clang "$CC_BIN" --typedump "$READER" -- $TFLAGS > "$W/$e.arm.log" 2>&1 || die "$e did not build for thumbv8m; see $W/$e.arm.log"
  done
  # shellcheck disable=SC2086
  "$CC_BIN" $TFLAGS -ffreestanding -c "$FIX/arm_main.c" -o "$W/arm_main.arm.o"
  # shellcheck disable=SC2086
  "$LD" -e spc_main --gc-sections -o "$W/two.arm.elf" $ARM_RING "$W/transport_uart.arm.o" \
    "$W/report.arm.o" "$W/send_n.arm.o" "$W/poll.arm.o" "$W/arm_main.arm.o" > "$W/two.link" 2>&1 && lrc=0 || lrc=$?
  ok "the two-channel application links for thumbv8m with the SDK's GNU ld, no undefined symbol" \
     "$lrc:$("$ROOT/tools/core/object-symbols" --undefined "$W/two.arm.elf" | wc -l | tr -d ' ')" "0:0"
  # shellcheck disable=SC2086
  ok "the thumbv8m image carries every label once, copy before publication, inside its function" \
     "$("$RUBY" "$TOOL" labels --object "$W/two.arm.elf" $CHARGS > "$W/labels.arm" 2>&1 && echo placed || cat "$W/labels.arm")" placed
  ok "control: a unit linked twice is a link error naming the duplicated function" \
     "$("$LD" -e spc_main -o "$W/dup.arm.elf" $ARM_RING "$W/channel_telemetry_put.arm.o" "$W/transport_uart.arm.o" \
          "$W/report.arm.o" "$W/send_n.arm.o" "$W/poll.arm.o" "$W/arm_main.arm.o" > "$W/dup.link" 2>&1 && echo linked || grep -c "multiple definition of .spc_channel_telemetry_put'" "$W/dup.link")" 1
else
  skipped "the thumbv8m link and its label check (ZEPHYR_SDK_INSTALL_DIR names the GNU linker)" 3
fi

echo
echo "channel: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
[ "$fail" = 0 ] || exit 1
