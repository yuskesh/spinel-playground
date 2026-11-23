#!/bin/sh
#
# tests/doom-core/native.sh — the playable program, through decision 0008's entries.
#
#   CORE_DIR=... ROUTE_DIR=... WAD=... LLVM_PREFIX=... SPINEL=... SPINEL_LIB=... \
#     sh tests/doom-core/native.sh DIR
#
# CORE_DIR holds the kernel's doom_core_*.o and the generated adapter's objects
# under adapter/obj/ (examples/doom/build.sh's layout). ROUTE_DIR is
# tests/doom-core/verify.sh's route directory, whose DEMO3 run holds the CRuby
# route's session-open snapshot, its layout and its catalog for the same
# configuration (DEMO3, key script `0 10 forward`). verify.sh runs this after
# its route part and reads the summary line.
#
# WHAT IT CHECKS
#   * the generated preparation is what tools/doom/core-native-prep.rb writes
#   * bin/doom.rb, built with the entries, plays DEMO1-3 with -core and every
#     frame is the original's recorded one (tests/doom-core/fixtures/screens)
#   * the session the program opens equals the CRuby route's at session open,
#     cell for cell, and its catalog equals Resources.catalog's, count for count
#   * built without the entries, -core refuses at session open and the old
#     paths still play the recorded frames (condition (a))
#   * controls, each planted on a live path of a copied tree and each asserted
#     by its message: a call into the sealed original game after the session
#     opened; a mode cell that is not 1; a pending rebirth; a generated read
#     that stores a wrong value
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: native.sh DIR}
RUBY=${RUBY:-ruby}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
SPINEL_LIB=${SPINEL_LIB:-$ROOT/vendor/spinel/lib}
TAB=$(printf "\t")
pass=0; fail=0; skip=0; skips=""
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1: $2 ($3)" >&2; skip=$((skip + 1)); skips="$skips
native: skipped $1: $2; enable with $3"; }
summary() {
  echo "native: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped$skips"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}
mkdir -p "$DIR" || exit 2
if [ -z "${CORE_DIR:-}" ] || [ ! -d "${CORE_DIR:-}" ] || [ -z "${ROUTE_DIR:-}" ] || [ ! -f "$WADFILE" ] ||
   [ -z "${LLVM_PREFIX:-}" ] || [ ! -x "$SPINEL" ]; then
  skipped "the playable program's lane" "it needs CORE_DIR, ROUTE_DIR, the IWAD, LLVM_PREFIX and the pinned compiler" \
    "CORE_DIR, ROUTE_DIR, WAD, LLVM_PREFIX and SPINEL (tests/doom-core/verify.sh sets them)"
  summary
fi
SHIM=$DIR/shim; mkdir -p "$SHIM"; ln -sf "$LLVM_PREFIX/bin/clang" "$SHIM/cc"
FIX=$ROOT/tests/doom-core/fixtures/screens
T0=$(date +%s)

echo "== the generated preparation is the generator's =="
"$RUBY" "$ROOT/tools/doom/core-native-prep.rb" --wad "$WADFILE" --out "$DIR/nativeprep.rb" > "$DIR/gen.out" 2>&1
ok "core-native-prep.rb writes examples/doom/core/full/nativeprep.rb" \
   "$?|$(cmp -s "$DIR/nativeprep.rb" "$ROOT/examples/doom/core/full/nativeprep.rb" && echo same)" "0|same"

# A copy of examples/doom (and the parts of examples/doom/core it reaches), so
# a control can plant its edit without touching the checkout.
tree() { # name
  rm -rf "$DIR/$1"; mkdir -p "$DIR/$1/examples"
  cp -R "$ROOT/examples/doom" "$DIR/$1/examples/doom"
}
build() { # tree-root out [CORE_DIR]
  ( cd "$1" && env LLVM_PREFIX="$LLVM_PREFIX" SPINEL="$SPINEL" SPINEL_LIB="$SPINEL_LIB" CORE_DIR="${3:-}" \
      BUILD_DIR="$2.d" OUT="$2" sh examples/doom/build.sh ) > "$2.build" 2>&1
}
play() { # binary demo frames [args...]
  b=$1; d=$2; f=$3; shift 3
  SDL_VIDEODRIVER=dummy "$b" -iwad "$WADFILE" -playdemo "$d" -nopace -frames "$f" "$@"
}
same_frames() { # demo frames
  grep -v '^#' "$FIX/$1.tsv" | cmp -s - "$(printf '%s' "$2")" 2>/dev/null
}

echo "== bin/doom.rb -core, built with the entries =="
tree core
build "$DIR/core" "$DIR/doom-core" "$CORE_DIR"
ok "the program builds with the entries" "$?|$(grep -c '^doom-build: -core links the entries from ' "$DIR/doom-core.build")" "0|1"
for e in DEMO1:5026 DEMO2:3836 DEMO3:2134; do
  d=${e%:*}; n=${e#*:}
  s=$(date +%s)
  play "$DIR/doom-core" "$d" "$DIR/$d.frames" -core > "$DIR/$d.out" 2>&1
  rc=$?
  grep -v '^#' "$DIR/$d.frames" > "$DIR/$d.got" 2>/dev/null
  grep -v '^#' "$FIX/$d.tsv" > "$DIR/$d.want"
  ok "$d -core: every tic through the entries, every frame the recorded one" \
     "$rc|$(wc -l < "$DIR/$d.got" | tr -d ' ')|$(cmp -s "$DIR/$d.want" "$DIR/$d.got" && echo same)|$(grep -c "^doom: -core $n tics through the entries$" "$DIR/$d.out")" \
     "0|$n|same|1"
  echo "  time $d -core: $(( $(date +%s) - s )) s; $(grep '^doom: -core session open' "$DIR/$d.out" | sed 's/^doom: -core //')"
done

echo "== the session it opens, against the CRuby route's (DEMO3) =="
OPEN=$DIR/core/tests/doom-core/native
mkdir -p "$OPEN"; cp "$ROOT/tests/doom-core/native/open.rb" "$OPEN/"
LINKS=""
for o in "$CORE_DIR"/doom_core_*.o "$CORE_DIR"/adapter/obj/*.o; do LINKS="$LINKS --link $o"; done
# shellcheck disable=SC2086
PATH=$SHIM:$PATH "$SPINEL" "$OPEN/open.rb" -o "$DIR/open" $LINKS --link -lpthread > "$DIR/open.build" 2>&1
ok "the session opener builds" "$?" 0
printf '0 10 forward\n' > "$DIR/script.txt"
mkdir -p "$DIR/open-out"
"$DIR/open" "$WADFILE" DEMO3 "$DIR/script.txt" "$DIR/open-out" > "$DIR/open.out" 2>&1
ok "  and opens DEMO3's session" "$?" 0
echo "  TRANSPORT, NOT VALUE: the program's preparation and the CRuby route's read the same"
echo "  objects, so their agreement shows that each generated read binds its field, and"
echo "  nothing about whether the field's value is right."
cmp_open() { # snapshot
  "$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$ROUTE_DIR/DEMO3/layout-0.tsv" \
    --a "$1" --b "$ROUTE_DIR/DEMO3/route-0.bin" --label-a native --label-b cruby-route --tic 0 2>&1
}
ok "  its snapshot equals the CRuby route's at session open" \
   "$(cmp_open "$DIR/open-out/native-0.bin" | grep -c '^compare-state: [0-9]* field(s), [0-9]* bytes, native and cruby-route agree at tic 0$')" 1
echo "  TWO PRODUCERS FOR rejectbytes, ON PURPOSE: the program takes the REJECT lump's directory"
echo "  size, CRuby the value's bytesize; a difference would be a finding about the WAD."
grep '^count' "$ROUTE_DIR/DEMO3/work/catalog.tsv" | sort > "$DIR/catalog.cruby"
sort "$DIR/open-out/native-catalog.tsv" > "$DIR/catalog.native"
ok "  its catalog equals Resources.catalog's, count for count" \
   "$(wc -l < "$DIR/catalog.native" | tr -d ' ')|$(cmp -s "$DIR/catalog.cruby" "$DIR/catalog.native" && echo same)" \
   "$(wc -l < "$DIR/catalog.cruby" | tr -d ' ')|same"

plant() { # name file ruby-anchor ruby-insertion
  tree "$1"
  "$RUBY" -e 'f, a, ins = ARGV; s = File.read(f); s.sub!(a) { a + ins } or abort("native.sh: no anchor in #{f}"); File.write(f, s)' \
    "$DIR/$1/$2" "$3" "$4"
}
echo "== a scripted run: the input entry, against the direct path =="
# The demos never call doom_core_input: their commands come from the lump. A
# key script does, and -core with -script builds its KeyScript exactly as the
# direct path does (bin/doom.rb core_play), handing preparation that object's
# own three arrays. The two runs must draw the same frames.
printf '0 20 forward\n10 30 right\n25 40 fire\n' > "$DIR/keys.txt"
scripted() { # out [args...]
  o=$1; shift
  SDL_VIDEODRIVER=dummy "$DIR/doom-core" -iwad "$WADFILE" -warp 1 1 -script "$DIR/keys.txt" -tics 45 \
    -nopace -frames "$o" "$@"
}
scripted "$DIR/script-direct.frames" > "$DIR/script-direct.out" 2>&1
rc=$?
scripted "$DIR/script-core.frames" -core > "$DIR/script-core.out" 2>&1
ok "a scripted run draws the same frames with -core as without" \
   "$rc|$?|$(grep -vc '^#' "$DIR/script-core.frames")|$(cmp -s "$DIR/script-direct.frames" "$DIR/script-core.frames" && echo same)" \
   "0|0|41|same"
# The key path with no keys down: bin/doom.rb reads the device (here SDL's
# dummy driver, which reports none) and hands doom_core_input the key table.
# Real keys are the Mac's acceptance; this checks the path, not a human.
SDL_VIDEODRIVER=dummy "$DIR/doom-core" -iwad "$WADFILE" -warp 1 1 -tics 30 -nopace \
  -frames "$DIR/idle-direct.frames" > "$DIR/idle-direct.out" 2>&1
rc=$?
SDL_VIDEODRIVER=dummy "$DIR/doom-core" -iwad "$WADFILE" -warp 1 1 -tics 30 -nopace \
  -frames "$DIR/idle-core.frames" -core > "$DIR/idle-core.out" 2>&1
ok "  a run driven by the device draws the same frames with -core as without" \
   "$rc|$?|$(grep -vc '^#' "$DIR/idle-core.frames")|$(cmp -s "$DIR/idle-direct.frames" "$DIR/idle-core.frames" && echo same)" \
   "0|0|30|same"
# Recording: the input entry writes the demo bytes, and Full saves the buffer
# it filled (native_loop.rb's save_recording is DemoWriter#save over the
# session). The file must be the direct path's, byte for byte.
scripted "$DIR/rec-direct.frames" -record "$DIR/rec-direct.lmp" > "$DIR/rec-direct.out" 2>&1
rc=$?
scripted "$DIR/rec-core.frames" -core -record "$DIR/rec-core.lmp" > "$DIR/rec-core.out" 2>&1
ok "  and a recorded demo is the direct path's file, byte for byte" \
   "$rc|$?|$(cmp -s "$DIR/rec-direct.lmp" "$DIR/rec-core.lmp" && echo same)|$(grep -c 'recorded 41 tics to' "$DIR/rec-core.out")" \
   "0|0|same|1"

plant script examples/doom/bin/doom.rb '  sealed = Doom::Core::SealedOriginals.new(g, r)
' '  s.put("key_script_code", 0, 0)
'
build "$DIR/script" "$DIR/doom-script" "$CORE_DIR"
SDL_VIDEODRIVER=dummy "$DIR/doom-script" -iwad "$WADFILE" -warp 1 1 -script "$DIR/keys.txt" -tics 45 \
  -nopace -frames "$DIR/script-planted.frames" -core > "$DIR/script-planted.out" 2>&1
# Every frame differs, from the first: the script's first key is the forward
# it holds from tic 0, so zeroing its code moves the player nowhere.
ok "  and a planted key in the script table changes every frame, from the first tic" \
   "$?|$(diff "$DIR/script-direct.frames" "$DIR/script-planted.frames" | grep -m1 '^[0-9]')" "0|2,42c2,42"

echo "== built without the entries (the old paths stay) =="
build "$ROOT" "$DIR/doom-plain"
ok "the program builds without CORE_DIR" "$?|$(grep -c '^doom-build: no CORE_DIR: native/sp_core_stub.c' "$DIR/doom-plain.build")" "0|1"
play "$DIR/doom-plain" DEMO3 "$DIR/plain-core.frames" -core > "$DIR/plain-core.out" 2>&1
ok "  -core refuses at session open" \
   "$?|$(grep -c 'the adapter registry would not start (1)' "$DIR/plain-core.out")" "1|1"
play "$DIR/doom-plain" DEMO3 "$DIR/plain.frames" > /dev/null 2>&1
ok "  the direct path still plays DEMO3's recorded frames" \
   "$?|$(grep -v '^#' "$DIR/plain.frames" | cmp -s "$DIR/DEMO3.want" - && echo same)" "0|same"
play "$DIR/doom-plain" DEMO3 "$DIR/plain-jobs.frames" -jobs > /dev/null 2>&1
ok "  and so does -jobs" \
   "$?|$(grep -v '^#' "$DIR/plain-jobs.frames" | cmp -s "$DIR/DEMO3.want" - && echo same)" "0|same"

echo "== controls, each planted on a live path =="
# The end of the core loop's input step, which only the core loop has: a plant
# here runs on the live path, before tic 5's step.
ANCHOR='      Doom::Core::NativeLoop.input(s, scripted ? 1 : 0, t, recording)
    end
'
plant sealed examples/doom/bin/doom.rb "$ANCHOR" '    sealed.game.g_ticker(0, 0, 0, 0) if t == 5
'
build "$DIR/sealed" "$DIR/doom-sealed" "$CORE_DIR"
play "$DIR/doom-sealed" DEMO3 "$DIR/sealed.frames" -core > "$DIR/sealed.out" 2>&1
ok "a call into the original game after the session opened is refused, on the live loop" \
   "$?|$(grep -vc '^#' "$DIR/sealed.frames")|$(grep -c 'the original game was reached after the session opened; the playable program runs the tic only through the entries' "$DIR/sealed.out")" "1|5|1"
plant mode examples/doom/bin/doom.rb "$ANCHOR" '    s.put("renderer_jobmode", 0, 1) if t == 5
'
build "$DIR/mode" "$DIR/doom-mode" "$CORE_DIR"
play "$DIR/doom-mode" DEMO3 "$DIR/mode.frames" -core > "$DIR/mode.out" 2>&1
ok "a mode cell that is not 0 is refused before the frame" \
   "$?|$(grep -vc '^#' "$DIR/mode.frames")|$(grep -c 'renderer_jobmode holds 1 before frame 6; the render is not called' "$DIR/mode.out")" "1|5|1"
plant reborn examples/doom/bin/doom.rb "$ANCHOR" '    s.put("game_pl_playerstate", 0, 2) if t == 5
'
build "$DIR/reborn" "$DIR/doom-reborn" "$CORE_DIR"
play "$DIR/doom-reborn" DEMO3 "$DIR/reborn.frames" -core > "$DIR/reborn.out" 2>&1
ok "a pending rebirth is refused before the step, on the live cell" \
   "$?|$(grep -vc '^#' "$DIR/reborn.frames")|$(grep -c 'rebirth is not supported: the player died and pressed use (game_pl_playerstate is PST_REBORN); the step is not called' "$DIR/reborn.out")" "1|5|1"
tree wrongread
mkdir -p "$DIR/wrongread/tests/doom-core/native"; cp "$ROOT/tests/doom-core/native/open.rb" "$DIR/wrongread/tests/doom-core/native/"
"$RUBY" -e 'f = ARGV[0]; s = File.read(f); s.sub!(%q{s.put("game_mobj_x", i, a[i])}, %q{s.put("game_mobj_x", i, a[i] + (i == 0 ? 1 : 0))}) or abort("no read"); File.write(f, s)' \
  "$DIR/wrongread/examples/doom/core/full/nativeprep.rb"
# shellcheck disable=SC2086
PATH=$SHIM:$PATH "$SPINEL" "$DIR/wrongread/tests/doom-core/native/open.rb" -o "$DIR/open-wrong" $LINKS --link -lpthread > "$DIR/open-wrong.build" 2>&1
mkdir -p "$DIR/wrong-out"
"$DIR/open-wrong" "$WADFILE" DEMO3 "$DIR/script.txt" "$DIR/wrong-out" > "$DIR/open-wrong.out" 2>&1
ok "a generated read that stores a wrong value is named by field and cell" \
   "$(cmp_open "$DIR/wrong-out/native-0.bin" | grep -c '^compare-state: value: game_mobj_x\[0\] at tic 0: native has ')" 1
echo "  time native lane: $(( $(date +%s) - T0 )) s"
summary
