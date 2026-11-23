#!/bin/sh
#
# tests/doom/interactive.sh — the SDL build agrees with the headless one.
#
#   WAD=$PWD/build/doom-wad/doom1.wad LLVM_PREFIX=/opt/llvm-23.1.1 \
#     tests/doom/interactive.sh
#
# What it establishes, and what it does not.
#
# A scripted input run drives the interactive binary with no human: the same
# key presses, on the same tics, every time.  That run records a `.lmp` and
# writes a per-tic frame hash TSV.  The recorded `.lmp` is then replayed through
# the HEADLESS binary, which shares the game logic and the renderer but not one
# line of SDL, and its frame hashes must be the same.  A difference means the
# SDL path changed something it has no business changing.
#
# It does NOT establish that the controls work.  A script fills the same
# `gamekeydown[]` array that SDL fills, so this exercises everything downstream
# of the key table and nothing upstream of it.  Whether pressing a key on a real
# keyboard reaches that table is the macOS real-window check, and it is not
# replaced by anything here.
#
# SKIP and FAIL are different outcomes and are decided by different things.
#
#   SKIP  the SDL AVAILABILITY PROBE fails.  tests/doom/native/sdl-probe.c calls
#         SDL_Init(SDL_INIT_VIDEO) and nothing else; if that cannot succeed,
#         there is no video device here and the comparison cannot run.
#   FAIL  everything else: the build broke, a stage exited non-zero, an output
#         is missing or short, or the frames disagree.
#
# The probe exists so that a failing GAME run is never read as a skip.  An
# earlier version looked for the word "SDL" in the game's log and skipped on it,
# which turns every real SDL fault -- a shim bug, a driver crash, a texture
# failure -- into a successful skip.  That is the one outcome a test must never
# produce.  Once the probe has succeeded, anything that fails afterwards is a
# failure.
#
# The video driver is never chosen by guessing.  An earlier version selected
# SDL's dummy driver when DISPLAY was unset, which is wrong on macOS, where
# DISPLAY is normally unset and a real window server is present.  The driver is
# whatever SDL picks, unless the caller sets SDL_VIDEODRIVER, and setting it to
# `dummy` is an explicit request for a headless frame comparison -- which is a
# different thing from the real-window check and is reported as such.
#
# What this does NOT establish, in any configuration: that the controls work.  A
# script fills the same `gamekeydown[]` array SDL fills, so everything
# downstream of the key table is exercised and nothing upstream of it.  Whether
# pressing a key on a real keyboard reaches that table is the macOS real-window
# check, and nothing here replaces it.
#
# Overrides: WAD, LLVM_PREFIX / CC, BUILD_DIR, SCRIPT, TICS, SPINEL,
# SDL_VIDEODRIVER.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD_DIR="${BUILD_DIR:-$ROOT/build/doom}"
WAD="${WAD:-$ROOT/build/doom-wad/doom1.wad}"
SCRIPT="${SCRIPT:-$ROOT/tests/doom/fixtures/scripts/script1.txt}"
TICS="${TICS:-350}"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
CC_BIN="${CC:-$LLVM_PREFIX/bin/clang}"

fail() { echo "interactive: FAIL $*" >&2; exit 1; }
skip() { echo "interactive: SKIP $*"; exit 0; }

[ -f "$WAD" ] || fail "no IWAD at $WAD -- run tools/doom/fetch-iwad.sh (this is a prerequisite failure, not a skip)"
[ -f "$SCRIPT" ] || fail "no input script at $SCRIPT"
[ -x "$SPINEL" ] || fail "no pinned compiler at $SPINEL"
[ -x "$CC_BIN" ] || fail "no C compiler at $CC_BIN"

if [ -n "${SDL2_CFLAGS:-}" ] || [ -n "${SDL2_LIBS:-}" ]; then
  : "${SDL2_CFLAGS:=}"
  : "${SDL2_LIBS:?SDL2_CFLAGS was given without SDL2_LIBS}"
else
  command -v pkg-config >/dev/null 2>&1 || fail "pkg-config is needed to find SDL2, or set SDL2_CFLAGS and SDL2_LIBS"
  pkg-config --exists sdl2 || fail "SDL2 development files not found by pkg-config; install them or set SDL2_CFLAGS and SDL2_LIBS"
  SDL2_CFLAGS=$(pkg-config --cflags sdl2)
  SDL2_LIBS=$(pkg-config --libs sdl2)
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-interactive.XXXXXX") || fail "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---- build both programs ---------------------------------------------------
echo "interactive: building the interactive binary"
LLVM_PREFIX="$LLVM_PREFIX" CC="$CC_BIN" BUILD_DIR="$BUILD_DIR" "$ROOT/examples/doom/build.sh" > "$WORK/build.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/build.log" | tail -20; fail "examples/doom/build.sh failed"; }
DOOM="$BUILD_DIR/doom"
[ -x "$DOOM" ] || fail "the build reported success but $DOOM is not executable"

echo "interactive: building the headless replayer"
"$SPINEL" "$ROOT/examples/doom/bin/sim_demo.rb" --cc="$CC_BIN" -o "$WORK/sim_demo" > "$WORK/sim.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/sim.log" | tail -20; fail "could not compile sim_demo.rb"; }

# ---- is there any video at all? -------------------------------------------
if [ -n "${SDL_VIDEODRIVER:-}" ]; then
  echo "interactive: SDL_VIDEODRIVER=$SDL_VIDEODRIVER was set by the caller; using it"
  if [ "$SDL_VIDEODRIVER" = dummy ]; then
    echo "interactive: this is a headless frame comparison, NOT a real-window check"
  fi
else
  echo "interactive: no SDL_VIDEODRIVER set; letting SDL choose"
fi

"$CC_BIN" -O2 $SDL2_CFLAGS "$ROOT/tests/doom/native/sdl-probe.c" $SDL2_LIBS -o "$WORK/sdl-probe" \
  > "$WORK/probe-build.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/probe-build.log" | tail -10; fail "could not build the SDL availability probe"; }

set +e
driver=$("$WORK/sdl-probe" 2> "$WORK/probe.log")
prc=$?
set -e
if [ "$prc" -eq 1 ]; then
  sed 's/^/    /' "$WORK/probe.log"
  skip "SDL cannot open a video device here.
    Set SDL_VIDEODRIVER=dummy to run the frame comparison without one."
fi
[ "$prc" -eq 0 ] || { sed 's/^/    /' "$WORK/probe.log"; fail "the SDL probe exited $prc, which is neither available nor unavailable"; }
echo "interactive: SDL video driver in use: $driver"
echo "interactive: the probe succeeded, so any later failure is a FAIL, not a skip"

# ---- the scripted run ------------------------------------------------------
echo "interactive: scripted run, $TICS tics, script $(basename "$SCRIPT")"
set +e
( cd "$WORK" && "$DOOM" -iwad "$WAD" -script "$SCRIPT" -record "$WORK/run.lmp" \
    -frames "$WORK/sdl-frames.tsv" -tics "$TICS" -nopace ) > "$WORK/run.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  # The probe already said SDL works here, so this is the program failing.
  sed 's/^/    /' "$WORK/run.log" | tail -20
  fail "the scripted run exited $rc (the SDL probe succeeded, so this is not an availability problem)"
fi
[ -s "$WORK/run.lmp" ] || fail "the scripted run produced no recording at run.lmp"
[ -s "$WORK/sdl-frames.tsv" ] || fail "the scripted run produced no frame hashes"

# ---- replay the recording headlessly ---------------------------------------
echo "interactive: replaying the recording through the headless build"
mkdir -p "$WORK/headless"
set +e
( cd "$WORK" && "$WORK/sim_demo" "$WAD" "@$WORK/run.lmp" "$TICS" "$WORK/headless" rand,player,mobj,frame ) \
  > "$WORK/replay.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { sed 's/^/    /' "$WORK/replay.log" | tail -20; fail "the headless replay exited $rc"; }
[ -s "$WORK/headless/frames.tsv" ] || fail "the headless replay produced no frame hashes"

# ---- compare ---------------------------------------------------------------
# Delegated, so the rule can be controlled on its own: both streams must carry
# exactly the requested tics, keyed 0..TICS-1, before they are compared.  Two
# files truncated the same way are equal and have compared almost nothing.
if "$ROOT/tests/doom/compare-frame-streams.sh" "$WORK/sdl-frames.tsv" "$WORK/headless/frames.tsv" "$TICS"; then
  echo "interactive: PASS (SDL driver $driver; $TICS frames identical between the SDL and headless paths)"
  exit 0
fi
fail "the SDL and headless frame streams do not agree"
