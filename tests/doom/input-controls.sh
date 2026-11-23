#!/bin/sh
#
# tests/doom/input-controls.sh — can two keys be held at once?
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 tests/doom/input-controls.sh
#   WAD=$PWD/build/doom-wad/doom1.wad LLVM_PREFIX=… tests/doom/input-controls.sh
#
# Written for a specific report: a player on macOS could move, turn, fire, open
# doors and quit, but was unsure whether UP and LEFT can be held together.
#
# The path from a key to the game has three layers, and they fail differently,
# so they are measured separately rather than as one end-to-end verdict:
#
#   1. a real key press becomes an SDL event.  The OS, the window server and
#      SDL's input backend are in this, and **none of it is testable here**.
#   2. an SDL event becomes a bit in the shim's keydown[256] table.
#      tests/doom/native/key-combination-probe.c pushes synthetic events with
#      SDL_PushEvent, pumps exactly as bin/doom.rb does, and reads the table
#      back.  It links the shim unmodified.
#   3. that table becomes a ticcmd.  tests/doom/cases-aux/ticcmd_combination.rb,
#      compiled by the pinned Spinel so it is the path the game runs.
#
# With a WAD there is also an end-to-end pass: the real game is driven by a
# script that holds both keys, records a demo, and the recorded ticcmds are read
# back.  That covers 2 and 3 inside the running game but still not 1.
#
# Nothing here decides whether the OS or the keyboard is at fault.  If all of
# these pass and the real window still misbehaves, that locates the problem in
# layer 1 -- which is a place to look, not a diagnosis.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
CC_BIN="${CC:-$LLVM_PREFIX/bin/clang}"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
WAD="${WAD:-}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-input.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0

fail_case() { echo "FAIL $*"; fail=$((fail + 1)); }
ok_case()   { echo "pass $*"; pass=$((pass + 1)); }

[ -x "$CC_BIN" ] || { echo "input-controls: no C compiler at $CC_BIN" >&2; exit 1; }
[ -x "$SPINEL" ] || { echo "input-controls: no pinned compiler at $SPINEL" >&2; exit 1; }
if [ -n "${SDL2_CFLAGS:-}" ] || [ -n "${SDL2_LIBS:-}" ]; then
  : "${SDL2_CFLAGS:=}"; : "${SDL2_LIBS:?SDL2_CFLAGS was given without SDL2_LIBS}"
else
  command -v pkg-config >/dev/null 2>&1 || { echo "input-controls: pkg-config needed for SDL2" >&2; exit 1; }
  pkg-config --exists sdl2 || { echo "input-controls: SDL2 development files not found" >&2; exit 1; }
  SDL2_CFLAGS=$(pkg-config --cflags sdl2); SDL2_LIBS=$(pkg-config --libs sdl2)
fi

# ---- layer 2: SDL events to the keydown table ------------------------------
# shellcheck disable=SC2086
"$CC_BIN" -O2 -Wall -Wextra $SDL2_CFLAGS "$ROOT/tests/doom/native/key-combination-probe.c" \
  "$ROOT/examples/doom/native/sp_sdl_shim.c" $SDL2_LIBS -o "$WORK/keyprobe" > "$WORK/kp.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/kp.log" | tail -10; fail_case "layer 2: could not build the key probe"; }
if [ -x "$WORK/keyprobe" ]; then
  set +e; "$WORK/keyprobe" > "$WORK/kp.out" 2>&1; rc=$?; set -e
  sed 's/^/    /' "$WORK/kp.out"
  if [ "$rc" -eq 2 ]; then
    echo "SKIP layer 2: SDL could not open a window here"
  elif [ "$rc" -eq 0 ]; then
    ok_case "layer 2: the shim holds UP and LEFT independently"
  else
    fail_case "layer 2: the shim did not hold the keys as expected (exit $rc)"
  fi
fi

# ---- layer 3: the keydown table to a ticcmd, compiled ----------------------
"$SPINEL" "$ROOT/tests/doom/cases-aux/ticcmd_combination.rb" --cc="$CC_BIN" -o "$WORK/ticcmd" \
  > "$WORK/tc.log" 2>&1 || { sed 's/^/    /' "$WORK/tc.log" | tail -10; fail_case "layer 3: could not compile the ticcmd probe"; }
if [ -x "$WORK/ticcmd" ]; then
  "$WORK/ticcmd" > "$WORK/tc.out" 2>&1 || true
  sed 's/^/    /' "$WORK/tc.out"
  fwd=$(awk -F'\t' '$1 == "up+left" {sub("forward=","",$2); print $2}' "$WORK/tc.out")
  trn=$(awk -F'\t' '$1 == "up+left" {sub("turn=","",$4); print $4}' "$WORK/tc.out")
  if [ "${fwd:-0}" -ne 0 ] && [ "${trn:-0}" -ne 0 ]; then
    ok_case "layer 3: up+left gives forward=$fwd and turn=$trn together"
  else
    fail_case "layer 3: up+left gave forward=${fwd:-?} turn=${trn:-?}; one of them is zero"
  fi
  # And releasing one side must leave the other.
  f2=$(awk -F'\t' '$1 == "up, left released" {sub("forward=","",$2); print $2}' "$WORK/tc.out")
  t2=$(awk -F'\t' '$1 == "up, left released" {sub("turn=","",$4); print $4}' "$WORK/tc.out")
  if [ "${f2:-0}" -ne 0 ] && [ "${t2:-1}" -eq 0 ]; then
    ok_case "layer 3: releasing LEFT leaves forward and clears turn"
  else
    fail_case "layer 3: after releasing LEFT, forward=${f2:-?} turn=${t2:-?}"
  fi
fi

# ---- end to end, if a WAD is available -------------------------------------
if [ -z "$WAD" ] || [ ! -f "$WAD" ]; then
  echo "note: no WAD given, so the end-to-end pass was not run (set WAD=...)"
else
  DOOM="${DOOM:-$ROOT/build/doom/doom}"
  if [ ! -x "$DOOM" ]; then
    echo "note: no interactive binary at $DOOM; run examples/doom/build.sh for the end-to-end pass"
  else
    cat > "$WORK/combo.txt" <<'SEOF'
0    34   up
35   69   left
70   139  up,left
140  174  up
175  209  left
SEOF
    ( cd "$WORK" && "$DOOM" -iwad "$WAD" -script "$WORK/combo.txt" -record "$WORK/combo.lmp" \
        -tics 210 -nopace ) > "$WORK/run.log" 2>&1 \
      || { sed 's/^/    /' "$WORK/run.log" | tail -10; fail_case "end to end: the scripted run failed"; }
    if [ -s "$WORK/combo.lmp" ]; then
      "$SPINEL" "$ROOT/examples/doom/bin/sim_demo.rb" --cc="$CC_BIN" -o "$WORK/sim" > "$WORK/sim.log" 2>&1
      mkdir -p "$WORK/out"
      ( cd "$WORK" && "$WORK/sim" "$WAD" "@$WORK/combo.lmp" 210 "$WORK/out" rand,player ) > "$WORK/replay.log" 2>&1 \
        || fail_case "end to end: the headless replay failed"
      if [ -s "$WORK/out/player.tsv" ]; then
        both=$(awk -F'\t' 'NR>1 && $6+0 != 0 && $8+0 != 0 {n++} END{print n+0}' "$WORK/out/player.tsv")
        rng=$(awk -F'\t' 'NR>1 && $6+0 != 0 && $8+0 != 0 {print $1}' "$WORK/out/player.tsv" \
              | awk 'NR==1{s=$1;p=$1;next}{if($1!=p+1){printf "%s-%s ",s,p; s=$1} p=$1}END{printf "%s-%s",s,p}')
        echo "    $both tic(s) recorded with forward and turn at once, at $rng"
        if [ "$both" -ge 60 ]; then
          ok_case "end to end: the recorded demo carries both at once"
        else
          fail_case "end to end: only $both tic(s) carried both, expected the script's 70"
        fi
      fi
    fi
  fi
fi

echo "input-controls: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
