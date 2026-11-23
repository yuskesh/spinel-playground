#!/bin/sh
#
# tests/doom-core/rt1186.sh — decision 0021's board lane: DOOM's entries on FRDM-IMXRT1186.
#
#   WAD=... LLVM_PREFIX=...|CLANG=... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... \
#     [CORE_BUILD=DIR] [THUMB_BUILD=DIR] [DEMOS="DEMO1 DEMO2 DEMO3"] [TICS=N] [RT1186_CORE=cm33|cm7] [RT1186_PAIR=1] [FUNCTION_SECTIONS=1] [RT1186_HOST=...] \
#     sh tests/doom-core/rt1186.sh DIR
#
# One demo per NOR write (0021, Clarification of 2026-10-20). For each demo
# the lane makes the board image and, with a board, plays it:
#
#   1. the three entries built for thumbv8m.main with their reports
#      (THUMB_BUILD: a previous run's DIR/thumb, reused; otherwise built here,
#      about four minutes), and the runtime helpers each object calls, recorded;
#   2. the host session program (tests/doom-core/native/bound.rb) over a host
#      kernel build (CORE_BUILD, in verify.sh's layout; built here when unset,
#      about eight minutes), which opens each demo's session and writes it at
#      open; tools/doom/session-image.rb --demo makes the image of it;
#   3. tests/app/session.sh over DEMO1's image and the thumbv8m objects: the
#      board loop on the host against Full's Demo object and the recording,
#      its build and record, and its refusals; with RT1186_PAIR=1 also
#      pair.rb and companion.rb together on the host, the frames relayed
#      through the companion's console (SESSION_PAIR=1);
#   4. examples/doom/core/board/app.rb built for frdm_imxrt1186 with each
#      demo's image, and tools/doom/nor-image.rb's NOR image of program and
#      session: within the 16 MB NOR, the FlexSPI configuration block (FCFB)
#      at 0x400;
#   5. with a board (RT1186_HOST, tests/doom-core/harness/rt1186-host.sh),
#      and only when every check before it passed
#      (tests/doom-core/harness/rt1186-board.sh): each NOR image written,
#      its console read only after a write that succeeded, from the lane's
#      own reset (rt_console records the console's length just before it;
#      what came before is the run the write's reset started), and
#      tools/doom/board-frames.rb decoding the 0014 frames from the first
#      boot after that length, requiring the build's own SPC_SESSION_ID
#      (build.json's session.id) before them, and every frame of the demo
#      to be the recorded one (tests/doom-core/fixtures/screens), in order,
#      and the run to end. With TICS=N, the console is read until the N-th frame and
#      only the first N frames are checked; the run is not waited for to end
#      (500 is about 14 s of DEMO1 and 80 s on the board, the 32-bit work's
#      check). Unset, every frame. The per-tic time is reported as
#      information, not as a bound.
#      Without a board the part is a skip, named; the reader's refusals are
#      checked on planted consoles either way.
#
# RT1186_PAIR=1 (decision 0027) builds examples/doom/core/board/pair.rb, the
# demo without its network stream, with --companion companion.rb: the M33
# image is that Spinel application, built in the same sysbuild, in the
# launcher's place. The board part then also requires the run to print the
# pair's ids, the ones build.json records, before its first frame
# (board-frames.rb --pair), and reads no network counts: the M33 runs no
# network firmware. Since stage 2 the M33 owns the console: pair.rb's lines
# reach it through the `console` contract channel and companion.rb relays
# them; the M33 prints the M7's ids and any refusal or fatal error for it,
# and the run starts at the M33's banner. Unset, the lane is app.rb's, as
# before.
#
# FAILURE_SITES=1 (a debugging aid) builds the entries with spinel-core-kernel
# --failure-sites and the board application with spinel-core-app
# --failure-sites: a failed DoomCore call prints SPC_FAILURE_SITE on the
# console, and the board part names its CORE unit and line
# (tools/doom/failure-site.rb). Its stack figures are a debugging build's.
#
# NOT A REALTIME CLAIM: the board loop's entry is built under the realtime
# profile with loop_bound unknown through DoomCore, and the summary says so.
# KERNEL, SPINEL_TYPEDUMP (or READER), ADAPTER, SPINEL and SPINEL_LIB select
# the tools as in verify.sh. Mostly long: it runs once, at the end of 0021.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: rt1186.sh DIR}
RUBY=${RUBY:-ruby}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
READER=${READER:-${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
ADAPTER_BIN=${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
SPINEL_LIB=${SPINEL_LIB:-$ROOT/vendor/spinel/lib}
PACK=$ROOT/tools/doom/pack-core.rb
DEMOS=${DEMOS:-DEMO1 DEMO2 DEMO3}
TICS=${TICS:-}
case $TICS in '') ;; *[!0-9]*|0) echo "rt1186: TICS must be a positive number of tics, not '$TICS'" >&2; exit 2 ;; esac
FIX=$ROOT/tests/doom-core/fixtures/screens
CLAIM="realtime profile, loop_bound unknown through DoomCore: not a realtime claim"
# RT1186_CORE: cm7 (the default), the board's Cortex-M7 behind the M33
# launcher (decision 0023): the board key the application is built for, and
# the target the entries are built for. cm33 (decision 0021's) is a named
# skip since decision 0024's amendment gave the M33 the network: DOOM's board
# application, with its frames channel, runs on the M7 only.
# NET: the network file of the application's frames channel (decision 0024),
# outside the repository for a run that sends; by default
# tests/app/fixtures/session/port0.net, which switches sending off (port 0),
# so the lane takes the same code path without sending.
case ${RT1186_CORE:-cm7} in
  cm33) RT1186_BOARD=frdm_imxrt1186 THUMB_FLAGS="--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os -ffreestanding" ;;
  cm7) RT1186_BOARD=frdm_imxrt1186_cm7 THUMB_FLAGS="--target=thumbv7em-none-eabi -mcpu=cortex-m7 -mfloat-abi=soft -mthumb -Os -ffreestanding" ;;
  *) echo "RT1186_CORE must be cm33 or cm7, not '$RT1186_CORE'" >&2; exit 2 ;;
esac
# FUNCTION_SECTIONS=1: each function of an entry in its own .text.<name> section, with
# its .ARM.exidx.text.<name>, so a build can place chosen functions (in ITCM, say);
# the kernel hands what follows -- to the clang that compiles its IR
[ -z "${FUNCTION_SECTIONS:-}" ] || THUMB_FLAGS="$THUMB_FLAGS -ffunction-sections"
pass=0; fail=0; skip=0; skips=""
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1: $2" >&2; skip=$((skip + 1)); skips="$skips
rt1186: skipped $1: $2"; }
T0=$(date +%s)
summary() {
  echo "rt1186: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped; $(( $(date +%s) - T0 )) s; $CLAIM$skips"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}
if [ "${RT1186_CORE:-cm7}" = cm33 ]; then
  skipped "the board lane on the Cortex-M33" "decision 0024's amendment gives the M33 the network, which a DOOM run on the M33 cannot share; RT1186_CORE=cm7 (the default) runs the lane"
  summary
fi
NET=${NET:-$ROOT/tests/app/fixtures/session/port0.net}
[ -f "$NET" ] || { echo "rt1186: NET names no network file ($NET)" >&2; exit 2; }
# the board application and its build's own options (decision 0027 for the pair)
case ${RT1186_PAIR:-} in
  '') BOARD_APP=$ROOT/examples/doom/core/board/app.rb ;;
  1) BOARD_APP=$ROOT/examples/doom/core/board/pair.rb ;;
  *) echo "rt1186: RT1186_PAIR is 1 or unset, not '$RT1186_PAIR'" >&2; exit 2 ;;
esac
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG; elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang; else CC_BIN=""; fi
mkdir -p "$DIR" || exit 2
if [ -z "$CC_BIN" ] || [ ! -f "$WADFILE" ] || [ ! -x "$KERNEL" ] || [ ! -x "$READER" ] || [ ! -x "$ADAPTER_BIN" ] ||
   [ ! -x "$SPINEL" ] || [ -z "${ZEPHYR_BASE:-}" ] || [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || ! command -v west > /dev/null 2>&1; then
  skipped "the board lane" "it needs the IWAD, LLVM_PREFIX or CLANG, the kernel, the reader, the adapter, the pinned compiler, ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west"
  summary
fi
LLVM_BIN=${CC_BIN%/*}
export ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR
SENTRIES="doom_core_input doom_core_step doom_core_render"
SRCFIX=$ROOT/tests/doom-core/fixtures/source
# shellcheck source=tests/doom-core/harness/artifacts.sh
. "$ROOT/tests/doom-core/harness/artifacts.sh"

echo "== 1. the entries for ${THUMB_FLAGS%% *} =="
T=${THUMB_BUILD:-$DIR/thumb}
if [ -z "${THUMB_BUILD:-}" ]; then
  s=$(date +%s)
  rm -rf "$T"; mkdir -p "$T/unit" "$T/stage"
  for f in $(grep -v '^#' "$ROOT/examples/doom/core/entries/units.tsv" | cut -f1); do cp "$ROOT/examples/doom/core/src/$f" "$T/unit/"; done
  cp "$ROOT/examples/doom/core/entries/units.tsv" "$T/manifest.tsv"
  # each entry packed on its own, at its manifest width (decision 0022 §2.6)
  prc=0
  for e in $SENTRIES; do
    mkdir -p "$T/stage/$e/src"
    "$RUBY" "$PACK" --manifest "$T/manifest.tsv" --root "$T/unit" --reader "$READER" --entry "$e" \
      --output "$T/stage/$e/src/packed.rb" --map "$T/stage/$e/map.tsv" > "$T/pack-$e.err" 2>&1 || prc=1
  done
  ok "the entries pack, each at its manifest width" "$prc" 0
  mkdir -p "$T/session-objects"
  for e in $SENTRIES; do
    cp "$ROOT/examples/doom/core/entries/$e.contract" "$T/stage/$e/"
    cp "$ROOT/examples/doom/core/entries/$e.contract" "$T/session-objects/"
    [ -z "${FAILURE_SITES:-}" ] || cp "$T/stage/$e/map.tsv" "$T/session-objects/$e.map.tsv"
    # shellcheck disable=SC2086
    ( "$KERNEL" "$T/stage/$e/$e.contract" --root "$T/stage/$e" --typedump "$READER" -o "$T/session-objects/$e.o" \
        --header "$T/session-objects/$e.h" --layout ptr32-i64-32long --report "$T/session-objects/report_$e.json" \
        ${FAILURE_SITES:+--failure-sites "$T/session-objects/$e.sites.tsv"} \
        --profile hosted-stage2 --clang "$CC_BIN" -- $THUMB_FLAGS > "$T/$e.raw" 2>&1; echo $? > "$T/$e.rc"
      # the kernel names the packed file; the maintained places are the units
      # and the manifest's width line (tools/doom/packed-place.rb)
      "$RUBY" "$ROOT/tools/doom/packed-place.rb" --map "$T/stage/$e/map.tsv" --packed "$T/stage/$e/src/packed.rb" \
        --units "$ROOT/examples/doom/core/src" --manifest "$ROOT/examples/doom/core/entries/units.tsv" \
        < "$T/$e.raw" > "$T/$e.err" 2>&1 || cp "$T/$e.raw" "$T/$e.err" ) &
  done
  wait
  echo "  time thumb entries: $(( $(date +%s) - s )) s"
fi
O=$T/session-objects
if [ -n "${THUMB_BUILD:-}" ]; then
  # reused objects must be this kernel's (tools/doom/objects-kernel.rb): an
  # older kernel's would be measured under this tree's name
  "$RUBY" "$ROOT/tools/doom/objects-kernel.rb" --kernel "$KERNEL" "$O" > "$DIR/thumb-kernel.out" 2>&1
  rc=$?
  ok "the reused THUMB_BUILD's objects were built by this kernel" "$rc" 0
  sed 's/^/  /' "$DIR/thumb-kernel.out"
  [ "$rc" = 0 ] || summary
fi
for e in $SENTRIES; do
  ok "$e builds for ${THUMB_FLAGS%% *} (ptr32), with its report" \
     "$(cat "$T/$e.rc" 2>/dev/null)|$("$LLVM_BIN/llvm-readelf" -h "$O/$e.o" 2>/dev/null | grep -c 'Machine:.*ARM')|$([ -f "$O/report_$e.json" ] && echo report)" "0|1|report"
  [ "$(cat "$T/$e.rc" 2>/dev/null)" = 0 ] || tail -n 3 "$T/$e.err" 2>/dev/null | sed 's/^/      /'
done
"$LLVM_BIN/llvm-nm" -u "$O"/doom_core_*.o 2>/dev/null | awk '/ U / { print $2 }' | LC_ALL=C sort -u > "$DIR/helpers.txt"
echo "  runtime helpers the objects call: $(tr '\n' ' ' < "$DIR/helpers.txt")"
ok "  every helper they call is attested in tools/app/zephyr/v4.4.2/helpers.tsv" \
   "$(while read -r h; do grep -q "^$h	" "$ROOT/tools/app/zephyr/v4.4.2/helpers.tsv" || echo "$h"; done < "$DIR/helpers.txt" | tr '\n' ' ')" ""

echo "== 2. each demo's session at open, and its image =="
H=${CORE_BUILD:-$DIR/host}
if [ -z "${CORE_BUILD:-}" ]; then
  s=$(date +%s)
  rm -rf "$H"
  dc_core_entries "$H" > "$DIR/host.out" 2>&1
  ok "the host kernel build of the three entries" "$?" 0
  echo "  time host entries: $(( $(date +%s) - s )) s"
else
  "$RUBY" "$ROOT/tools/doom/objects-kernel.rb" --kernel "$KERNEL" "$H" > "$DIR/host-kernel.out" 2>&1
  rc=$?
  ok "the reused CORE_BUILD's objects were built by this kernel" "$rc" 0
  sed 's/^/  /' "$DIR/host-kernel.out"
  [ "$rc" = 0 ] || summary
fi
rm -rf "$DIR/adapter"
dc_route_adapter "$H" "$DIR/adapter" > "$DIR/adapter.out" 2>&1
rc=$?
for c in "$DIR/adapter"/spinel_adapter_*.c; do
  "$CC_BIN" -std=c11 -O1 -I"$DIR/adapter" -c "$c" -o "$DIR/adapter/obj/$(basename "$c" .c).o" >> "$DIR/adapter.out" 2>&1 || rc=$?
done
"$CC_BIN" -std=c11 -O1 -c "$ROOT/tests/doom-core/native/bound_map.c" -o "$DIR/bound_map.o" >> "$DIR/adapter.out" 2>&1 || rc=$?
mkdir -p "$DIR/shim"; ln -sf "$CC_BIN" "$DIR/shim/cc"
LINKS="--link $DIR/bound_map.o"
for o in "$H"/doom_core_*.o "$DIR"/adapter/obj/*.o; do LINKS="$LINKS --link $o"; done
# shellcheck disable=SC2086
PATH=$DIR/shim:$PATH SPINEL_LIB="$SPINEL_LIB" "$SPINEL" "$ROOT/tests/doom-core/native/bound.rb" -o "$DIR/bound" \
  $LINKS --link -lpthread > "$DIR/bound.build" 2>&1 || rc=$?
ok "the host session program builds" "$rc" 0
for d in $DEMOS; do
  mkdir -p "$DIR/open-$d"
  "$DIR/bound" "$WADFILE" "$d" 0 "$DIR/open-$d" alloc > "$DIR/open-$d.out" 2>&1
  "$RUBY" "$ROOT/tools/doom/session-image.rb" --catalog "$DIR/open-$d/native-catalog.tsv" --snapshot "$DIR/open-$d/native-0.bin" \
    --out "$DIR/image-$d" --demo "$d" > "$DIR/image-$d.out" 2>&1
  ok "$d: its session image, with its demo recorded, and the digests sha256sum -c accepts" \
     "$?|$(grep -c "^#demo	$d	" "$DIR/image-$d/image.tsv")|$(cd "$DIR/image-$d" && sha256sum -c image.sha256 2>&1 | grep -c ': OK$')" "0|1|3"
  sed 's/^/  /' "$DIR/image-$d.out"
done

echo "== 3. the session lane over DEMO1 =="
case " $DEMOS " in
  *" DEMO1 "*)
    SESSION_IMAGE="$DIR/image-DEMO1" SESSION_OBJECTS="$O" WAD="$WADFILE" KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" CLANG="$CC_BIN" \
      SESSION_BOARD=$RT1186_BOARD SESSION_NET="$NET" SESSION_PAIR="${RT1186_PAIR:-}" sh "$ROOT/tests/app/session.sh" "$DIR/session" > "$DIR/session.out" 2>&1
    ok "tests/app/session.sh" \
       "$?|$(awk '/^session: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" { n++ } END { print n + 0 }' "$DIR/session.out")" "0|1"
    sed 's/^/    /' "$DIR/session.out" ;;
  *) skipped "the session lane" "DEMOS does not name DEMO1" ;;
esac

echo "== 4. each demo's board image =="
for d in $DEMOS; do
  rm -rf "$DIR/fw-$d"
  # the build is handed this lane's kernel and reader, not whatever the environment holds
  KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" \
    "$RUBY" "$ROOT/tools/app/bin/spinel-core-app" build --app "$BOARD_APP" --board "$RT1186_BOARD" \
    --out "$DIR/fw-$d" --session-image "$DIR/image-$d" --session-objects "$O" \
    $(if [ -n "${RT1186_PAIR:-}" ]; then echo --companion "$ROOT/examples/doom/core/board/companion.rb"; else echo --net "$NET"; fi) \
    ${FAILURE_SITES:+--failure-sites} > "$DIR/fw-$d.out" 2>&1
  ok "$d: the board application builds, and build.json records the claim" \
     "$?|$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["session"]["claim"]' "$DIR/fw-$d/firmware/build.json" 2>/dev/null)" "0|$CLAIM"
  "$RUBY" "$ROOT/tools/doom/nor-image.rb" --firmware "$DIR/fw-$d/firmware" --image "$DIR/image-$d" --out "$DIR/nor-$d.bin" \
    --llvm "${LLVM_BIN%/bin}" > "$DIR/nor-$d.out" 2>&1
  ok "  its NOR image: program and session, within the 16 MB NOR, the FlexSPI configuration block at 0x400" \
     "$?|$([ "$(wc -c < "$DIR/nor-$d.bin" 2>/dev/null || echo 99999999)" -le 16777216 ] && echo fits)|$(od -A n -c -j 1024 -N 4 "$DIR/nor-$d.bin" 2>/dev/null | tr -d ' ')" "0|fits|FCFB"
  sed 's/^/  /' "$DIR/nor-$d.out"
done

# The console reader, on planted consoles framed as the board frames them
# (tests/doom-core/harness/rt1186-consoles.rb): where the run starts (--from,
# the lane's reset), a second boot, a broken frame, a fault, a refused
# session, a missing or another build's SPC_SESSION_ID and a line of the
# SHA-256 form each fail, named; the clean console, and an earlier run before
# --from, are admitted.
mkdir -p "$DIR/consoles"
"$RUBY" "$ROOT/tests/doom-core/harness/rt1186-consoles.rb" "$FIX/DEMO1.tsv" "$DIR/consoles" > "$DIR/consoles/rows.tsv"
while IFS="$(printf '\t')" read -r n from partial tics identity want; do
  out=$("$RUBY" "$ROOT/tools/doom/board-frames.rb" --console "$DIR/consoles/$n.log" --frames "$FIX/DEMO1.tsv" --identity "$identity" \
    --from "$from" $([ "$partial" = 1 ] && echo --partial) $([ "$tics" != 0 ] && echo --tics "$tics") 2>&1); rc=$?
  if [ "$want" = pass ]; then
    ok "board-frames admits the $n console" "$rc" 0
  else
    ok "board-frames refuses the $n console: $want" "$rc|$(printf '%s' "$out" | grep -cF "$want")" "1|1"
  fi
done < "$DIR/consoles/rows.tsv"

# The board's lock, on this host in place of RT1186_HOST (RT1186_RSH runs the
# harness's remote commands here): one run takes it, a second is refused and
# told who holds it, the holder's exit releases it, a lock nobody here took is
# never removed, and a host that cannot be asked is not read as a held board.
lockctl() { # what -> the answer of the case, run in its own shell
  ( RT1186_RES=$DIR/lockctl; RT1186_HOST=here; RT1186_RSH="sh -c"; RT1186_LOCK=$DIR/lockctl/lock
    mkdir -p "$RT1186_RES"
    # shellcheck source=tests/doom-core/harness/rt1186-host.sh
    . "$ROOT/tests/doom-core/harness/rt1186-host.sh"
    case $1 in
      take) RT1186_OWNER=first; rt_lock > /dev/null && echo "taken:$(sed -n 's/^owner //p' "$RT1186_LOCK/owner")" ;;
      second) RT1186_OWNER=first; rt_lock > /dev/null
              ( RT1186_LOCK_TOKEN=; RT1186_OWNER=second; rt_lock > "$RT1186_RES/second.txt" 2>&1; echo "rc $?" ) ;;
      released) RT1186_OWNER=first; rt_lock > /dev/null; exit 0 ;;
      stale) mkdir -p "$RT1186_LOCK"; printf 'owner gone\npid 1\nstarted then\ntoken old\n' > "$RT1186_LOCK/owner"
             RT1186_OWNER=third; rt_lock > "$RT1186_RES/stale.txt" 2>&1; echo "rc $?" ;;
      unreachable) RT1186_RSH=false; rt_lock > /dev/null 2>&1; echo "rc $?" ;;
    esac )
}
rm -rf "$DIR/lockctl"
ok "the board's lock: a run takes it and records its owner" "$(lockctl take)" "taken:first"
ok "  its exit releases it" "$([ -d "$DIR/lockctl/lock" ] && echo held || echo free)" free
ok "  a second run is refused while it is held" "$(lockctl second)" "rc 1"
ok "  and is told who holds it" "$(grep -c '^  owner first$' "$DIR/lockctl/second.txt")" 1
lockctl released > /dev/null
ok "  the holder's exit releases it" "$([ -d "$DIR/lockctl/lock" ] && echo held || echo free)" free
ok "  a lock this run did not take refuses it" "$(lockctl stale)" "rc 1"
ok "  and is left where it was" "$(sed -n 's/^token //p' "$DIR/lockctl/lock/owner")" old
rm -rf "$DIR/lockctl/lock"
ok "  a host that cannot be asked is not a held board" "$(lockctl unreachable)" "rc 2"

# The board part, without a board (tests/doom-core/board-controls.sh): the
# same function part 5 runs, over a planted write and planted consoles. A
# failed write is not followed by a read, and another build's console or a
# frame that is not the recorded one fails the lane's own check, with TICS
# and without.
RUBY="$RUBY" sh "$ROOT/tests/doom-core/board-controls.sh" "$DIR/board-controls" > "$DIR/board-controls.out" 2>&1
ok "tests/doom-core/board-controls.sh" \
   "$?|$(awk '/^board-controls: [0-9]+ checked, / && $2 == $4 && $6 == "0" { n++ } END { print n + 0 }' "$DIR/board-controls.out")" "0|1"
sed 's/^/    /' "$DIR/board-controls.out"

echo "== 5. on the board =="
RT1186_RES=$DIR/board; mkdir -p "$RT1186_RES"
# shellcheck source=tests/doom-core/harness/rt1186-host.sh
. "$ROOT/tests/doom-core/harness/rt1186-host.sh"
# shellcheck source=tests/doom-core/harness/rt1186-board.sh
. "$ROOT/tests/doom-core/harness/rt1186-board.sh"
# shellcheck source=tests/doom-core/harness/rt1186-gdb.sh
. "$ROOT/tests/doom-core/harness/rt1186-gdb.sh"
# shellcheck source=tests/doom-core/harness/rt1186-net.sh
. "$ROOT/tests/doom-core/harness/rt1186-net.sh"
# shellcheck source=tests/doom-core/harness/rt1186-pair.sh
. "$ROOT/tests/doom-core/harness/rt1186-pair.sh"
# nothing is written after a failure (rt1186_board_gate)
rt1186_board_gate || summary
# the board first: no probe is touched before the lock is this run's
lockrc=0
if [ -n "${RT1186_HOST:-}" ]; then
  rt_lock > "$RT1186_RES/lock.txt" 2>&1 || lockrc=$?
  if [ "$lockrc" = 1 ]; then
    ok "the board is free (its lock on RT1186_HOST)" "$(sed -n '1p' "$RT1186_RES/lock.txt")" "taken"
    sed 's/^/  /' "$RT1186_RES/lock.txt"
    summary
  fi
fi
if [ "$lockrc" = 2 ]; then
  skipped "the board part" "$(cat "$RT1186_RES/lock.txt")"
elif why=$(rt_ready); then
  rt_open || exit 1
  HZ=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$DIR/fw-$(echo $DEMOS | cut -d' ' -f1)/firmware/config")
  for d in $DEMOS; do
    s=$(date +%s)
    rt1186_board_demo "$d" "$HZ"
    # the frames channel's other end: the M33's counts (decision 0024); the
    # pair's M33 runs no network firmware (decision 0027)
    [ -n "${RT1186_PAIR:-}" ] || rt1186_net_counts "$d"
    # the pair console channel: its counts close after a drained run (decision 0027 stage 2)
    [ -z "${RT1186_PAIR:-}" ] || rt1186_pair_counts "$d"
    echo "  time board $d: $(( $(date +%s) - s )) s"
  done
else
  skipped "the board part" "$why"
fi
summary
