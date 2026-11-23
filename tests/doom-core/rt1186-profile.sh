#!/bin/sh
#
# tests/doom-core/rt1186-profile.sh -- one demo's stage times on the FRDM-IMXRT1186.
#
#   KERNEL=... SPINEL_TYPEDUMP=... LLVM_PREFIX=... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... \
#     RT1186_HOST=user@host [RT1186_PROBE=...] [RT1186_TTY=...] [DEMO=DEMO1] [TICS=N] \
#     sh tests/doom-core/rt1186-profile.sh LANE_DIR DIR
#
# TICS=N reads the console until the N-th frame, as rt1186.sh's TICS does,
# judges those N frames, and keeps the stage times of the tics below N.
#
# PCSAMPLE=PERIOD_US (with TICS) also builds the PC sampler of
# `spinel-core-app build --pcsample` into the image: GPT1 records the PC the
# loop's thread was at every PERIOD_US until the N-th tic. After the console,
# the samples are read out with a debugger (harness/rt1186-gdb.sh) into
# DIR/pcs/, and tools/doom/board-pcsample.rb counts them by function and by
# the object (the stage) each lies in.
#
# LANE_DIR is a finished tests/doom-core/rt1186.sh run's DIR: its thumb
# entries (LANE_DIR/thumb/session-objects) and the demo's session image
# (LANE_DIR/image-DEMOn) are taken from it as they are. This builds
# examples/doom/core/board/profile.rb (app.rb's loop, timed by stage) with
# them, assembles its NOR image (tools/doom/nor-image.rb), writes and reads
# it as rt1186.sh does (tests/doom-core/harness/rt1186-host.sh: the console
# from the lane's own reset, and only after a write that succeeded), and runs
# tools/doom/board-profile.rb. That judges the run's frames with
# board-frames.rb first, with --identity the build's id from build.json, which
# the run must print before its frames; then it writes
# DIR/profile/stages.tsv and DIR/profile/summary.txt.
#
# It is a measurement, not the acceptance: rt1186.sh and app.rb are that, and
# this changes neither. NOT A REALTIME CLAIM: the times are information.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LANE=${1:?usage: rt1186-profile.sh LANE_DIR DIR}
DIR=${2:?usage: rt1186-profile.sh LANE_DIR DIR}
RUBY=${RUBY:-ruby}
DEMO=${DEMO:-DEMO1}
TICS=${TICS:-}
case $TICS in '') ;; *[!0-9]*|0) echo "rt1186-profile: TICS must be a positive number of tics, not '$TICS'" >&2; exit 2 ;; esac
PCSAMPLE=${PCSAMPLE:-}
case $PCSAMPLE in '') ;; *[!0-9]*|0) echo "rt1186-profile: PCSAMPLE must be a positive period in microseconds, not '$PCSAMPLE'" >&2; exit 2 ;; esac
[ -z "$PCSAMPLE" ] || [ -n "$TICS" ] || { echo "rt1186-profile: PCSAMPLE needs TICS, the tics it samples" >&2; exit 2; }
FIX=$ROOT/tests/doom-core/fixtures/screens
# RT1186_CORE: cm33 (the default, decision 0021) or cm7, the board's Cortex-M7
# behind the M33 launcher (decision 0023): the board key the application is
# built for, and the target the entries are built for
case ${RT1186_CORE:-cm33} in
  cm33) RT1186_BOARD=frdm_imxrt1186 THUMB_FLAGS="--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os -ffreestanding" ;;
  cm7) RT1186_BOARD=frdm_imxrt1186_cm7 THUMB_FLAGS="--target=thumbv7em-none-eabi -mcpu=cortex-m7 -mfloat-abi=soft -mthumb -Os -ffreestanding" ;;
  *) echo "RT1186_CORE must be cm33 or cm7, not '$RT1186_CORE'" >&2; exit 2 ;;
esac
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG; elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang; else CC_BIN=""; fi
die() { echo "rt1186-profile: $*" >&2; exit 2; }
[ -n "$CC_BIN" ] || die "set LLVM_PREFIX or CLANG"
[ -d "$LANE/thumb/session-objects" ] && [ -f "$LANE/image-$DEMO/image.tsv" ] ||
  die "$LANE is not a finished rt1186.sh run with $DEMO (no thumb/session-objects or image-$DEMO)"
# the kernel must be this tree's source (tools/test/source-stamp.rb), and the
# lane's objects this kernel's (tools/doom/objects-kernel.rb): different facts
. "$ROOT/tools/test/source-stamp.sh"
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
READER=${READER:-${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}}
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
"$RUBY" "$ROOT/tools/doom/objects-kernel.rb" --kernel "$KERNEL" \
  "$LANE/thumb/session-objects" || die "$LANE's entries were not built by this kernel: rebuild the lane, or give its KERNEL"
mkdir -p "$DIR" || exit 2
s0=$(date +%s)

rm -rf "$DIR/fw"
# the build is handed this lane's kernel and reader, not whatever the environment holds
KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" \
  "$RUBY" "$ROOT/tools/app/bin/spinel-core-app" build --app "$ROOT/examples/doom/core/board/profile.rb" --board "$RT1186_BOARD" \
  --out "$DIR/fw" --session-image "$LANE/image-$DEMO" --session-objects "$LANE/thumb/session-objects" ${PCSAMPLE:+--pcsample "$PCSAMPLE,$TICS"} > "$DIR/fw.out" 2>&1 ||
  { tail -3 "$DIR/fw.out"; die "the profile variant did not build; see $DIR/fw.out"; }
"$RUBY" "$ROOT/tools/doom/nor-image.rb" --firmware "$DIR/fw/firmware" --image "$LANE/image-$DEMO" --out "$DIR/nor-$DEMO.bin" \
  --llvm "${CC_BIN%/bin/*}" > "$DIR/nor.out" 2>&1 || { cat "$DIR/nor.out"; die "no NOR image"; }
cat "$DIR/nor.out"
# the build the console must name before its frames (board-frames.rb --identity)
ID=$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("session", "id").to_s' "$DIR/fw/firmware/build.json")
echo "$ID" | grep -qE '^[0-9a-f]{16}$' || die "$DIR/fw/firmware/build.json names no build id (session.id)"

RT1186_RES=$DIR/board; mkdir -p "$RT1186_RES"
# shellcheck source=tests/doom-core/harness/rt1186-host.sh
. "$ROOT/tests/doom-core/harness/rt1186-host.sh"
rt_lock > "$RT1186_RES/lock.txt" 2>&1 || { cat "$RT1186_RES/lock.txt"; die "the board is not ours"; }
why=$(rt_ready) || die "no board: $why"
rt_open || exit 1
rt_flash "profile-$DEMO" "$DIR/nor-$DEMO.bin" || die "the write failed; see $RT1186_RES/flash_profile-$DEMO.log"
# a write whose log does not say it finished leaves an earlier image on the board: not read
grep -qiE 'finished|success' "$RT1186_RES/flash_profile-$DEMO.log" || die "the write did not say it finished; see $RT1186_RES/flash_profile-$DEMO.log"
rt_console "profile-$DEMO" "${TICS:-0}"
HZ=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$DIR/fw/firmware/config")
"$RUBY" "$ROOT/tools/doom/board-profile.rb" --console "$RT1186_RES/serial_profile-$DEMO.log" \
  --from "$(cat "$RT1186_RES/serial_profile-$DEMO.reset")" --frames "$FIX/$DEMO.tsv" --identity "$ID" --hz "$HZ" --out "$DIR/profile" \
  ${TICS:+--tics "$TICS"}
rc=$?
if [ -n "$PCSAMPLE" ]; then
  # shellcheck source=tests/doom-core/harness/rt1186-gdb.sh
  . "$ROOT/tests/doom-core/harness/rt1186-gdb.sh"
  # the sampler's record is in the application core's memory: on the M7, read through it
  [ "${RT1186_CORE:-cm33}" = cm7 ] && RT1186_GDB_CORE=cm7
  ELF=$DIR/fw/firmware/zephyr.elf
  addr() { "${CC_BIN%/*}/llvm-nm" "$ELF" | awk -v s="$1" '$3 == s { print "0x" $1 }'; }
  mkdir -p "$DIR/pcs"
  # one debugger session: the record, then as many samples as it counts
  rec=$(addr spc_pcs)
  rt_gdb_read "$DIR/pcs/record.bin" "$rec" 48 \
    "$DIR/pcs/samples.bin" "$(addr spc_pcs_pc)" "4 * *(unsigned int *)$((rec + 4))" || die "the sampler's record could not be read"
  n=$(od -A n -t u4 -j 4 -N 4 "$DIR/pcs/record.bin" | tr -d ' ')
  [ "$(wc -c < "$DIR/pcs/samples.bin" | tr -d ' ')" = "$((n * 4))" ] || die "the samples could not be read: not $n of them"
  "$RUBY" "$ROOT/tools/doom/board-pcsample.rb" --record "$DIR/pcs/record.bin" --samples "$DIR/pcs/samples.bin" \
    --elf "$ELF" --map "$DIR/fw/firmware/zephyr.map" --nm "${CC_BIN%/*}/llvm-nm" --hz "$HZ" --out "$DIR/pcs" || rc=1
fi
echo "rt1186-profile: $DEMO, rc $rc, $(( $(date +%s) - s0 )) s; the times are information, not a realtime claim"
exit $rc
