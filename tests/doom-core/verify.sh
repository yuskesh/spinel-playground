#!/bin/sh
#
# tests/doom-core/verify.sh — decision 0008's three entries, built and compared.
#
#   WAD=... sh tests/doom-core/verify.sh [DIR]
#
# THE LANE THAT SUPERSEDES THE RETIRED STAGE-1 LANES (decision 0009,
# clarification of 2026-09-17). It runs, in this order:
#
#   entries   tests/doom-core/entries.sh: the entries are what their generator
#             writes, and their field map holds against the generated layout
#   input     tests/doom-core/input-diff.rb: doom_core_input against the original
#             input step, scripted and polled, recording and not, and at a full
#             demo buffer
#   content   tests/doom-core/content-scan.rb: the ledger's claims that the
#             shipped IWAD, or any content, never runs a definition, with one
#             planted input per kind of claim; and tests/doom-core/refusals.rb:
#             every "not implemented" raise of the original, and what stands
#             behind the port stopping where it stops
#   build     harness/artifacts.sh's dc_core_entries: the three entries packed
#             from examples/doom/core/entries/units.tsv and compiled by the
#             kernel, each object with one export, nothing undefined, and no
#             relocation whose resolution depends on another object
#             (tests/doom-core/object-relocs.rb, with its refusals shown by
#             tests/doom-core/object-relocs.sh on arm64 objects built here)
#   step      tests/doom-core/step-diff.rb over every tic of each demo
#   scenario  step-diff.rb over tests/doom-core/scenarios.rb's synthesised starts
#             (V7): the definitions the shipped IWAD reaches and no demo does,
#             each required to be entered, and the witnesses that the port stops
#             where the original's "not implemented" raises stop it
#   coverage  tests/doom-core/step-coverage.rb: the step lines those runs ran --
#             the denominator of their zeros -- and every definition none of them
#             entered is one a content or construction claim names
#   render    tests/doom-core/render-diff.rb over every frame of each demo, in job
#             mode 1, and SCALED_FRAMES frames of DEMO1 at --scale 2 (the status
#             bar's shadow path)
#   route     Full's job-mode-1 route (examples/doom/core/full/route.rb): the
#             built entries through their generated adapter, every tic of each
#             demo by tests/doom-core/route-demo.rb; its screens against the
#             original's recordings (tests/doom-core/fixtures/screens), and its
#             state at checkpoints against the original's
#             (tests/doom-core/route-reference.rb, compare-state.rb), with the
#             controls for the mode, the rebirth, both comparisons and the
#             session-open-only cells; and tests/doom-core/graph-guard.rb
#   nsdiff    tests/doom-core/native-scenario-diff.sh: the SAME scenario corpus
#             the `scenario` part runs in CORE-source execution, run against the
#             COMPILED step entry -- so that every definition the corpus
#             exercises is exercised in both (decision 0009's clarification of
#             2026-09-18). Scalars after every tic, all of the state after the
#             first tic and after the last, the scenarios that stop stopping in
#             the same tic on both sides, and two planted controls
#   widths    tests/doom-core/widths.sh: decision 0018's width table
#             (examples/doom/core/widths.tsv) against every demo played through
#             the compiled entries, every value the port runs above stored
#             (tools/doom/core-store-ranges.rb) and a fresh scan of the
#             stores, with three planted controls
#   capacity  tests/doom-core/capacity.sh: the knot stack's capacity contract --
#             every push carries its check (by the generator, with a mutated
#             generator refused), and exhaustion is deterministic and writes
#             nothing past the end, witnessed at the floor and partway through
#             a demo
#   native    tests/doom-core/native.sh: bin/doom.rb -core, built with the
#             entries by the pinned compiler, over DEMO1-3 against the
#             recordings, its session against the route's, the old paths
#             without the entries, and its planted controls
#   bound-resources  tests/doom-core/bound-resources.sh: decision 0021, the
#             same program over resources bound to a read-only session image
#             written from this run's kernel build
#
# The build, the six demo runs, the scaled run and the scenarios go side by
# side; each part prints its wall
# time, and the run prints the total. DEMOS narrows the demos for a run that is
# iterating, and says so as a skip; REQUIRE_ALL=1 turns every skip into a
# failure. A part whose tool is absent is a skip naming it, never a pass.
#
# Tools: KERNEL (spinel-core-kernel), SPINEL_TYPEDUMP (the contract reader),
# LLVM_PREFIX or CLANG (the compiler), ADAPTER (spinel-core-adapter) and WAD
# (the IWAD), as tick.sh takes them; SPINEL and SPINEL_LIB (the pinned compiler
# and its runtime) for the native part.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:-${TMPDIR:-/tmp}/doom-core-verify.$$}
RUBY=${RUBY:-ruby}
PACK=$ROOT/tools/doom/pack-core.rb
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
ADAPTER_BIN=${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else CC_BIN=""; fi
LLVM_BIN=${CC_BIN%/*}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
ALL_DEMOS="DEMO1 DEMO2 DEMO3"
DEMOS=${DEMOS:-$ALL_DEMOS}
SCALED_FRAMES=${SCALED_FRAMES:-200}
SCENARIOS="punch saw chaingun backpack soulsphere power-invisibility power-suit power-allmap power-visor
switch teleport telefrag baron-attack baron-death walk-36 use-9 shoot-46 exit-11 reborn"
# the stop witnesses and the message the original stops with
WITNESSES="baron-death:A_BossDeath~reached walk-36:P_CrossSpecialLine: use-9:P_UseSpecialLine: shoot-46:P_ShootSpecialLine:
exit-11:E1M8~exit~sector"
mkdir -p "$DIR" || exit 2
. "$ROOT/tests/doom-core/harness/artifacts.sh"

TAB=$(printf "\t")
# A demo's tic count. A function, not `$(case ...)`: macOS /bin/sh is bash
# 3.2, which cannot parse a case inside a command substitution.
tics_of() {
  case $1 in DEMO1) echo 5026 ;; DEMO2) echo 3836 ;; DEMO3) echo 2134 ;; esac
}
pass=0; fail=0; skip=0; skips=""
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1 ($2)"; skip=$((skip + 1)); skips="$skips  - $1: $2
"; }
T0=$(date +%s)
# EVERY PORT RUN RECORDS ITS STORES (decision 0018): tools/doom/core-store-ranges.rb
# loads the runner unchanged and keeps the range of every value the entries store,
# for tests/doom-core/widths.sh. The runner's output and status are its own.
STORES=$DIR/store-ranges
mkdir -p "$STORES"
rec() { # label runner args...
  dc_l=$1; shift
  "$RUBY" "$ROOT/tools/doom/core-store-ranges.rb" --output "$STORES/$dc_l.tsv" --label "$dc_l" "$@"
}
took() { echo "  time $1: $(( $(date +%s) - $2 )) s"; }

echo "== the entries and their field map =="
t=$(date +%s)
sh "$ROOT/tests/doom-core/entries.sh" > "$DIR/entries.out" 2>&1
ok "entries.sh passes" "$?|$(tail -1 "$DIR/entries.out" | sed 's/.* \([0-9]*\) fail$/\1/')" "0|0"
took entries "$t"

echo "== the input entry against the original input step =="
t=$(date +%s)
rec input "$ROOT/tests/doom-core/input-diff.rb" > "$DIR/input.out" 2>&1
ok "every input run agrees" "$?|$(tail -1 "$DIR/input.out")" "0|input-diff: every run agreed"
took input "$t"

[ -f "$WADFILE" ] || { skipped "the build and the demo runs" "no IWAD at $WADFILE; set WAD"; WADFILE=""; }
[ "$DEMOS" = "$ALL_DEMOS" ] || skipped "the demos DEMOS leaves out" "DEMOS is '$DEMOS', not '$ALL_DEMOS'"

echo "== code no shipped content runs, checked against the IWAD =="
# tools/doom/core-migrated.tsv's absent-in-content and unreached-by-construction
# claims (tests/doom-core/content-scan.rb), and one planted input per kind of
# claim: a cacodemon placed in E1M1, a fire-flicker sector in E1M1, and a copy of
# the table with a wrong type list and a thinker the original does create.
t=$(date +%s)
if [ -n "$WADFILE" ]; then
  CS=$ROOT/tests/doom-core/content-scan.rb
  "$RUBY" "$CS" "$WADFILE" > "$DIR/content.out" 2>&1
  ok "every content and construction claim holds" "$?|$(tail -1 "$DIR/content.out" | sed 's/ over .*//')" \
     "0|content-scan: 9 claim(s), all hold"
  plant() { # what out
    mkdir -p "$(dirname "$2")"
    "$RUBY" -e '
      require_relative ARGV[0]
      wad = Doom::Wad.new(ARGV[1]); b = File.binread(ARGV[1])
      i = wad.index_of("E1M1")
      case ARGV[2]
      when "thing" then l = wad.lump(i + 1); b[l.pos + 6, 2] = [3005].pack("S<")
      when "mega" then l = wad.lump(i + 1); b[l.pos + 6, 2] = [83].pack("S<")
      when "bfg" then l = wad.lump(i + 1); b[l.pos + 6, 2] = [2006].pack("S<")
      else l = wad.lump(i + 8); b[l.pos + 22, 2] = [17].pack("s<") end
      File.binwrite(ARGV[3], b)' "$ROOT/examples/doom/lib/doom/wad" "$WADFILE" "$1" "$2"
  }
  plant thing "$DIR/cs-thing/doom1.wad"
  "$RUBY" "$CS" --planted-control "$DIR/cs-thing/doom1.wad" > "$DIR/cs-thing.out" 2>&1
  ok "  a cacodemon placed in E1M1 is refused by name" "$?|$(grep -c '^refused .*a_head_attack .*type 3005 is placed in E1M1$' "$DIR/cs-thing.out")" "1|1"
  plant sector "$DIR/cs-sector/doom1.wad"
  "$RUBY" "$CS" --planted-control "$DIR/cs-sector/doom1.wad" > "$DIR/cs-sector.out" 2>&1
  ok "  a fire-flicker sector in E1M1 is refused by name" "$?|$(grep -c '^refused .*t_fire_flicker .*sector special 17 is in E1M1$' "$DIR/cs-sector.out")" "1|1"
  "$RUBY" "$CS" "$DIR/cs-thing/doom1.wad" > "$DIR/cs-unpinned.out" 2>&1 && rc=0 || rc=$?
  ok "  an IWAD that is not the pinned one is refused without the control flag" \
     "$rc|$(grep -c 'is not the pinned doom1.wad (docs/doom.md SHA-256 ' "$DIR/cs-unpinned.out")" "1|1"
  plant mega "$DIR/cs-mega/doom1.wad"
  "$RUBY" "$CS" --planted-control "$DIR/cs-mega/doom1.wad" > "$DIR/cs-mega.out" 2>&1
  ok "  a megasphere placed in E1M1 is refused by name" "$?|$(grep -c '^refused .*sprite=MEGA: type 83 (sprite MEGA) is placed in E1M1$' "$DIR/cs-mega.out")" "1|1"
  plant bfg "$DIR/cs-bfg/doom1.wad"
  "$RUBY" "$CS" --planted-control "$DIR/cs-bfg/doom1.wad" > "$DIR/cs-bfg.out" 2>&1
  ok "  a pickup with no case placed in E1M1 is refused by name" "$?|$(grep -c '^refused .*gettable-unlisted: type 2006 (sprite BFUG) has no case and is placed in E1M1$' "$DIR/cs-bfg.out")" "1|1"
  # claims that are wrong, empty, or on the wrong definition
  claim_mutant() { # label sed-expression pattern
    sed "$2" "$ROOT/tools/doom/core-migrated.tsv" > "$DIR/cs-claim.tsv"
    "$RUBY" "$CS" "$WADFILE" "$DIR/cs-claim.tsv" > "$DIR/cs-claim.out" 2>&1
    ok "  $1" "$?|$(grep -c "$3" "$DIR/cs-claim.out")" "1|1"
  }
  claim_mutant "a wrong type list is refused" 's/things=3006/things=3006+3001/' \
    'the types reaching a_skull_attack are 3006, not 3001,3006'
  claim_mutant "a thinker kind the original creates is refused" 's/thinker=TH_CEILING/thinker=TH_DOOR/' \
    'a TH_DOOR thinker runs "t_vertical_door", not t_move_ceiling'
  claim_mutant "a thinker kind the original does not define is refused" 's/thinker=TH_CEILING/thinker=TH_NOPE/' \
    'TH_NOPE is no thinker kind the original defines'
  claim_mutant "a sprite the definition has no case for is refused" 's/sprite=MEGA/sprite=ZZZZ/' \
    'give_by_sprite has no case for sprite ZZZZ'
  "$RUBY" -e '
    rows = File.readlines(ARGV[0]).map do |l|
      f = l.split("\t", -1)
      if f[0] == "Game#t_move_ceiling" then f[1] = f[1].sub(",unreached-by-construction:thinker=TH_CEILING", "")
      elsif f[0] == "Game#t_glow" then f[1] += ",unreached-by-construction:thinker=TH_CEILING" end
      f.join("\t")
    end
    File.write(ARGV[1], rows.join)' "$ROOT/tools/doom/core-migrated.tsv" "$DIR/cs-moved.tsv"
  "$RUBY" "$CS" "$WADFILE" "$DIR/cs-moved.tsv" > "$DIR/cs-moved.out" 2>&1
  ok "  a claim moved onto a definition the demos run is refused" \
     "$?|$(grep -c 'a TH_CEILING thinker runs "t_move_ceiling", not t_glow' "$DIR/cs-moved.out")" "1|1"
  # spawns and thinkers written in forms the scan must still read
  lib_mutant() { # label ruby-statement pattern
    rm -rf "$DIR/cs-lib"; mkdir -p "$DIR/cs-lib"; cp "$ROOT"/examples/doom/lib/doom/*.rb "$DIR/cs-lib/"
    "$RUBY" -e 'f = ARGV[0]; s = File.read(f)
      s.sub!("    def a_boss_death(_actor)", "    def planted_x(actor)\n      #{ARGV[1]}\n    end\n\n    def a_boss_death(_actor)") or abort("anchor")
      File.write(f, s)' "$DIR/cs-lib/enemy.rb" "$2"
    "$RUBY" "$CS" --lib "$DIR/cs-lib" "$WADFILE" > "$DIR/cs-lib.out" 2>&1
    ok "  $1" "$?|$(grep -c "$3" "$DIR/cs-lib.out")" "1|1"
  }
  lib_mutant "a lost soul spawned by type number is refused" 'spawn_mobj(0, 0, 0, 18)' 'a_skull_attack.*the original spawns type 3006'
  lib_mutant "a spawn under a qualified constant is refused" 'spawn_mobj(i32(@mobj_x[actor]), 0, 0, Info::MT_SKULL)' 'a_skull_attack.*the original spawns type 3006'
  lib_mutant "a thinker created without parentheses is refused" 'add_thinker TH_CEILING, actor' 'planted_x create(s) TH_CEILING'
  lib_mutant "a thinker stored straight into @th_func is refused" '@th_func[actor] = TH_CEILING' 'planted_x create(s) TH_CEILING'
  lib_mutant "a thinker kind held in a local is refused" 'k = TH_CEILING; add_thinker(k, actor)' "add_thinker's kind is not a constant"
  lib_mutant "a fire flicker made under another case's when 17 is refused" \
    'case actor when 17 then spawn_fire_flicker(actor) end' 'TH_FIREFLICKER is made by spawn_fire_flicker at enemy.rb'
  # every "not implemented" raise of the original, accounted for
  "$RUBY" "$ROOT/tests/doom-core/refusals.rb" > "$DIR/refusals.out" 2>&1
  ok "every not-implemented raise of the original has its row" "$?" 0
  sed 's/^/    /' "$DIR/refusals.out"
  grep -v "^specials.rb${TAB}P_ShootSpecialLine" "$ROOT/tools/doom/core-refusals.tsv" > "$DIR/refusals-short.tsv"
  "$RUBY" "$ROOT/tests/doom-core/refusals.rb" "$DIR/refusals-short.tsv" > "$DIR/refusals-short.out" 2>&1
  ok "  and a raise with no row is refused" \
     "$?|$(grep -c 'raise "P_ShootSpecialLine: line #{line} special #{sp} not implemented" matches 0 row(s)' "$DIR/refusals-short.out")" "1|1"
fi
took content "$t"

# FULL'S ROUTE (V3): the adapter generated and linked for the built entries,
# then every demo through route-demo.rb with its checkpoints, the original's
# state at the same checkpoints, and the controls on DEMO3's first tics. Run in
# the background after the build; the checks read what it wrote.
route_runs() {
  R=$DIR/route; mkdir -p "$R"
  s=$(date +%s)
  dc_route_adapter "$DIR/build" "$R/adapter" > "$R/adapter.out" 2>&1 &&
    dc_adapter_link "$DIR/build" "$R/adapter" "$R/libdoomcore.so" >> "$R/adapter.out" 2>&1
  echo "rc=$? $(( $(date +%s) - s ))" > "$R/adapter.rc"
  [ -f "$R/libdoomcore.so" ] || return 0
  L="$R/libdoomcore.so $R/adapter"
  for d in $DEMOS; do
    ( tics=$(tics_of "$d")
      ck=0,1,2,3; k=500; while [ "$k" -lt "$tics" ]; do ck=$ck,$k; k=$((k + 500)); done; ck=$ck,$tics
      echo "$ck" > "$R/$d.ck"; mkdir -p "$R/$d"
      s=$(date +%s)
      "$RUBY" "$ROOT/tests/doom-core/route-demo.rb" "$WADFILE" "$d" 100000 $L "$R/$d/work" \
        --snapshot "$ck" --snapdir "$R/$d" > "$R/$d.screens" 2> "$R/$d.err"
      echo "rc=$? $(( $(date +%s) - s ))" > "$R/$d.rc"
      "$RUBY" "$ROOT/tests/doom-core/route-reference.rb" "$WADFILE" "$d" "$R/$d/work/gen/snapshot.tsv" \
        "$ROOT/examples/doom/core/state.tsv" "$ck" "$R/$d" > "$R/$d.ref" 2>&1
      echo "$?" > "$R/$d.refrc" ) &
  done
  # the controls, each on DEMO3's first tics, each in a directory of its own
  ctl() { # name ntics args...
    c=$1; n=$2; shift 2; mkdir -p "$R/ctl-$c"
    "$RUBY" "$ROOT/tests/doom-core/route-demo.rb" "$WADFILE" DEMO3 "$n" $L "$R/ctl-$c/work" "$@" \
      > "$R/ctl-$c.screens" 2> "$R/ctl-$c.err"
    echo "$?" > "$R/ctl-$c.rc"
  }
  ( ctl mode0 8 --mode 0
    ctl mode4 8 --plant renderer_jobmode=4@0
    ctl reborn 8 --plant game_pl_playerstate=2@5
    ctl health 101 --plant game_pl_health=5@100 --snapshot 100 --snapdir "$R/ctl-health"
    grep -v '^#' "$ROOT/tests/doom-core/fixtures/screens/DEMO3.tsv" | head -n 101 > "$R/ctl-health.want"
    "$RUBY" "$ROOT/tests/doom-core/route-reference.rb" "$WADFILE" DEMO3 "$R/ctl-health/work/gen/snapshot.tsv" \
      "$ROOT/examples/doom/core/state.tsv" 100 "$R/ctl-health" > "$R/ctl-health.ref" 2>&1
    ctl open 1 --plant renderer_dc_srcres=0@0 --snapshot 0 --snapdir "$R/ctl-open"
    "$RUBY" "$ROOT/tests/doom-core/route-reference.rb" "$WADFILE" DEMO3 "$R/ctl-open/work/gen/snapshot.tsv" \
      "$ROOT/examples/doom/core/state.tsv" 0 "$R/ctl-open" > "$R/ctl-open.ref" 2>&1 ) &
  wait
  # the playable program, once the route's session-open snapshot exists
  mkdir -p "$R/native-core/adapter"
  ln -sf "$DIR"/build/doom_core_*.o "$R/native-core/"
  ln -sfn "$R/adapter/obj" "$R/native-core/adapter/obj"
  s=$(date +%s)
  CORE_DIR="$R/native-core" ROUTE_DIR="$R" WAD="$WADFILE" REQUIRE_ALL="${REQUIRE_ALL:-}" \
    sh "$ROOT/tests/doom-core/native.sh" "$R/native" > "$R/native.out" 2>&1
  echo "rc=$? $(( $(date +%s) - s ))" > "$R/native.rc"
  # DECISION 0021: the entries over resources bound to a read-only session
  # image, with this run's kernel build as CORE_BUILD
  s=$(date +%s)
  CORE_BUILD="$DIR/build" WAD="$WADFILE" ADAPTER="$ADAPTER_BIN" READER="$READER" CLANG="$CC_BIN" \
    REQUIRE_ALL="${REQUIRE_ALL:-}" \
    sh "$ROOT/tests/doom-core/bound-resources.sh" "$R/bound-resources" > "$R/bound-resources.out" 2>&1
  echo "rc=$? $(( $(date +%s) - s ))" > "$R/bound-resources.rc"
  # THE SCENARIO CORPUS THROUGH THE COMPILED ENTRY, over the same library: the
  # `scenario` part runs these in CORE-source execution, and this runs them
  # here (decision 0009's clarification of 2026-09-18).
  s=$(date +%s)
  LIB="$R/libdoomcore.so" HEADERS="$R/adapter" WAD="$WADFILE" \
    sh "$ROOT/tests/doom-core/native-scenario-diff.sh" "$R/nsdiff" > "$R/nsdiff.out" 2>&1
  echo "rc=$? $(( $(date +%s) - s ))" > "$R/nsdiff.rc"
}

echo "== the three entries, built; the step and render entries over every demo =="
t=$(date +%s)
if [ -x "$KERNEL" ] && [ -x "$READER" ] && [ -n "$CC_BIN" ] && [ -x "$CC_BIN" ]; then
  ( RUBY=$RUBY ROOT=$ROOT PACK=$PACK READER=$READER KERNEL=$KERNEL CC_BIN=$CC_BIN
    s=$(date +%s); dc_core_entries "$DIR/build"; brc=$?; echo "rc=$brc $(( $(date +%s) - s ))" > "$DIR/build.rc"
    # FULL'S ROUTE, once the entries exist: see route_runs below
    if [ "$brc" -eq 0 ] && [ -n "$WADFILE" ] && [ -x "$ADAPTER_BIN" ]; then route_runs; fi ) &
  building=yes
else
  skipped "the kernel build" "KERNEL, SPINEL_TYPEDUMP and LLVM_PREFIX or CLANG must name built tools"
  building=no
fi
if [ -n "$WADFILE" ]; then
  mkdir -p "$DIR/cov"
  for d in $DEMOS; do
    ( s=$(date +%s); rec "step-$d" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" "$d" 100000 --coverage "$DIR/cov/demo-$d.json" > "$DIR/step-$d.out" 2>&1
      echo "rc=$? $(( $(date +%s) - s ))" > "$DIR/step-$d.rc" ) &
    ( s=$(date +%s); rec "render-$d" "$ROOT/tests/doom-core/render-diff.rb" "$WADFILE" "$d" 100000 > "$DIR/render-$d.out" 2>&1
      echo "rc=$? $(( $(date +%s) - s ))" > "$DIR/render-$d.rc" ) &
  done
  ( s=$(date +%s); rec render-scaled "$ROOT/tests/doom-core/render-diff.rb" "$WADFILE" DEMO1 "$SCALED_FRAMES" --scale 2 > "$DIR/render-scaled.out" 2>&1
    echo "rc=$? $(( $(date +%s) - s ))" > "$DIR/render-scaled.rc" ) &
  # the planted control of 0022 section 2.4: the original's angle words handed
  # in unconverted (--raw-repr) must fail; not recorded, so the width table
  # never sees their stores
  ( "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" DEMO1 100 --raw-repr > "$DIR/raw-step.out" 2>&1
    "$RUBY" "$ROOT/tests/doom-core/render-diff.rb" "$WADFILE" DEMO1 5 --raw-repr > "$DIR/raw-render.out" 2>&1 ) &
  # tests/doom-core/scenarios.rb's synthesised starts, and three planted defects
  ( s=$(date +%s)
    for sc in $SCENARIOS; do
      rec "scenario-$sc" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" "scenario:$sc" 1000 --coverage "$DIR/cov/sc-$sc.json" > "$DIR/scenario-$sc.out" 2>&1
      echo "$?" > "$DIR/scenario-$sc.rc"
    done
    mkdir -p "$DIR/scc"
    for c in nostop rename value late same; do rm -rf "$DIR/scc/$c"; cp -R "$ROOT/examples/doom/core/src" "$DIR/scc/$c"; done
    "$RUBY" -e '
      d = ARGV[0]
      f = "#{d}/nostop/stepcore.rb"; s = File.read(f)
      s.sub!("def dc_st_a_boss_death(actor)\n  core_fail(:capacity)\n  actor\nend", "def dc_st_a_boss_death(actor)\n  actor\nend") or abort("no a_boss_death")
      File.write(f, s)
      f = "#{d}/rename/stepknot.rb"; s = File.read(f)
      s.gsub!(/\bdc_st_kp_a_punch\b/, "dc_st_kp_a_punch_x") or abort("no a_punch")
      File.write(f, s)
      f = "#{d}/late/stepcore.rb"; s = File.read(f)
      s.sub!("def dc_st_a_boss_death(actor)\n  core_fail(:capacity)\n  actor\nend", "def dc_st_a_boss_death(actor)\n  $planted = 1\n  actor\nend") or abort("no late a_boss_death")
      File.write(f, s)
      f = "#{d}/late/doomentry.rb"; s = File.read(f)
      s.sub!("  msg = dc_st_take_message(state, gx)\n", "  core_fail(:capacity) if $planted\n  msg = dc_st_take_message(state, gx)\n") or abort("no take_message")
      File.write(f, s)
      f = "#{d}/value/stepwork.rb"; s = File.read(f)
      s.sub!("      pl_maxammo[i] = pl_maxammo[i] * 2\n", "      pl_maxammo[i] = pl_maxammo[i] * 3\n") or abort("no backpack")
      File.write(f, s)' "$DIR/scc"
    "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" scenario:baron-death 1000 --src "$DIR/scc/nostop" > "$DIR/scc-nostop.out" 2>&1
    "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" scenario:punch 1000 --src "$DIR/scc/rename" > "$DIR/scc-rename.out" 2>&1
    "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" scenario:backpack 1000 --src "$DIR/scc/value" > "$DIR/scc-value.out" 2>&1
    "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" scenario:baron-death 1000 --src "$DIR/scc/late" > "$DIR/scc-late.out" 2>&1
    "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" scenario:reborn 1000 --no-full-guard > "$DIR/scc-backstop.out" 2>&1
    "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" scenario:baron-death 1000 --src "$DIR/scc/same" > "$DIR/scc-same.out" 2>&1
    echo "$(( $(date +%s) - s ))" > "$DIR/scenarios.time" ) &
fi
wait
# THE WIDTH TABLE, RE-MEASURED (decision 0018), over the route's library and the
# stores every port run above recorded: after the wait, because it needs them all.
if [ -f "$DIR/route/libdoomcore.so" ]; then
  s=$(date +%s)
  LIB="$DIR/route/libdoomcore.so" HEADERS="$DIR/route/adapter" WAD="$WADFILE" STORE_RANGES="$STORES" \
    sh "$ROOT/tests/doom-core/widths.sh" "$DIR/route/widths" > "$DIR/route/widths.out" 2>&1
  echo "rc=$? $(( $(date +%s) - s ))" > "$DIR/route/widths.rc"
fi
if [ "$building" = yes ]; then
  ok "the kernel builds all three" "$(cut -d' ' -f1 "$DIR/build.rc")" "rc=0"
  echo "  time build: $(cut -d' ' -f2 "$DIR/build.rc") s"
  CC="$CC_BIN" REQUIRE_ALL="${REQUIRE_ALL:-}" sh "$ROOT/tests/doom-core/object-relocs.sh" "$DIR/relocs" > "$DIR/relocs.out" 2>&1
  ok "the relocation guard refuses what depends on another object (object-relocs.sh)" \
     "$?|$(awk '/^object-relocs: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" { n++ } END { print n + 0 }' "$DIR/relocs.out")" "0|1"
  sed 's/^/    /' "$DIR/relocs.out"
  for e in doom_core_input doom_core_step doom_core_render; do
    o=$DIR/build/$e.o
    if [ -f "$o" ]; then
      ok "  $e: one export, nothing undefined" \
         "$("$LLVM_BIN/llvm-nm" --defined-only --extern-only "$o" | awk '{print $NF}' | sed 's/^_//' | tr '\n' ' ')|$("$LLVM_BIN/llvm-nm" -u "$o" | wc -l | tr -d ' ')" "spinel_core_$e |0"
      ok "  $e: every relocation stays in the object" \
         "$("$RUBY" "$ROOT/tests/doom-core/object-relocs.rb" "$LLVM_BIN" "$o" | head -1)" "$e ok"
    else
      ok "  $e was written" "absent" "present"
    fi
  done
fi
if [ -n "$WADFILE" ]; then
  for d in $DEMOS; do
    tics=$(tics_of "$d")
    ok "step, $d: every tic agrees" "$(cut -d' ' -f1 "$DIR/step-$d.rc")|$(grep -c "^step-diff: $d $tics tic(s), 0 disagreeing" "$DIR/step-$d.out")" "rc=0|1"
    echo "  time step $d: $(cut -d' ' -f2 "$DIR/step-$d.rc") s"
    ok "render, $d: every frame agrees" "$(cut -d' ' -f1 "$DIR/render-$d.rc")|$(grep -c "^render-diff: $d $tics frame(s), 0 disagreeing" "$DIR/render-$d.out")" "rc=0|1"
    echo "  time render $d: $(cut -d' ' -f2 "$DIR/render-$d.rc") s"
  done
  ok "render at scale 2, DEMO1: every frame agrees" \
     "$(cut -d' ' -f1 "$DIR/render-scaled.rc")|$(grep -c "^render-diff: DEMO1 $SCALED_FRAMES frame(s), 0 disagreeing" "$DIR/render-scaled.out")" "rc=0|1"
  echo "  time render scaled: $(cut -d' ' -f2 "$DIR/render-scaled.rc") s"
  ok "  and the angles handed in unconverted (--raw-repr) fail, in step and in render" \
     "$(grep -c '^step-diff: 1 distinct error(s): CoreIntrinsics::Arithmetic' "$DIR/raw-step.out")|$(grep -c '^render-diff: 1 distinct error(s): CoreIntrinsics::Arithmetic' "$DIR/raw-render.out")" "1|1"
  for sc in $SCENARIOS; do
    ok "scenario $sc: its targets entered, every tic agrees" \
       "$(cat "$DIR/scenario-$sc.rc")|$(grep -c 'never entered' "$DIR/scenario-$sc.out")|$(grep -c 'tic(s), 0 disagreeing' "$DIR/scenario-$sc.out")" "0|0|1"
  done
  for w in $WITNESSES; do
    sc=${w%%:*}; msg=$(echo "${w#*:}" | tr '~' ' ')
    ok "  witness $sc: the original raises $msg, and the port stops at the same tic, in its stop_in" \
       "$(grep -c "^tic [0-9]*: both stopped -- the original raised \"$msg" "$DIR/scenario-$sc.out")" 1
  done
  ok "  rebirth: Full refuses before the call, at the tic the original raises" \
     "$(grep -c '^tic 31: Full refused before the call -- the original raised "G_DoReborn' "$DIR/scenario-reborn.out")" 1
  ok "  and without Full's check, CORE's backstop stops at that same tic" \
     "$(grep -c '^tic 31: both stopped -- the original raised "G_DoReborn' "$DIR/scc-backstop.out")|$(grep -c 'tic(s), 0 disagreeing' "$DIR/scc-backstop.out")" "1|1"
  ok "  a port that refuses at the same tic but elsewhere is refused" \
     "$(grep -c 'A_BossDeath reached (not implemented for this map)" and the port raised CoreFail: core_fail(:capacity) at .*/late/doomentry.rb:.*, not in dc_st_a_boss_death' "$DIR/scc-late.out")" 1
  ok "  and an unmodified copy loaded the same way still stops where it should" \
     "$(grep -c '^tic 94: both stopped' "$DIR/scc-same.out")" 1
  ok "  a port that does not stop there is refused" \
     "$(grep -c 'A_BossDeath reached (not implemented for this map)" and the port did not stop' "$DIR/scc-nostop.out")" 1
  ok "  a scenario whose target is never entered is refused" \
     "$(grep -c 'scenario punch never entered dc_st_kp_a_punch' "$DIR/scc-rename.out")" 1
  ok "  a planted backpack defect is a disagreement" \
     "$(grep -c 'game_pl_maxammo cell 0: port 600 original 400' "$DIR/scc-value.out")" 1
  echo "  time scenarios and their controls: $(cat "$DIR/scenarios.time") s"
  # THE DENOMINATOR OF THE ZEROS ABOVE: the step lines the demos and the
  # scenarios ran (tests/doom-core/step-coverage.rb), printed in full, and a
  # definition nothing entered refused unless a content or construction claim
  # names it -- shown refusing with the punch scenario's record left out.
  CV=$ROOT/tests/doom-core/step-coverage.rb
  # A NARROWED RUN SKIPS THIS, IT DOES NOT FAIL IT: the denominator is every
  # demo, and with fewer the refusal below names definitions only the others
  # enter. The refusal is not softened; the check is not run.
  if [ "$DEMOS" != "$ALL_DEMOS" ]; then
    skipped "the step coverage check" "its denominator needs every demo, and DEMOS is '$DEMOS'"
  else
    "$RUBY" "$CV" "$DIR"/cov/demo-*.json -- "$DIR"/cov/sc-*.json > "$DIR/coverage.out" 2>&1
    ok "every definition no comparison enters is claimed unrunnable" "$?" 0
    sed 's/^/    /' "$DIR/coverage.out"
    "$RUBY" "$CV" "$DIR"/cov/demo-*.json -- $(ls "$DIR"/cov/sc-*.json | grep -v 'sc-punch.json') > "$DIR/coverage-nopunch.out" 2>&1
    ok "  and one no comparison enters without a claim is refused" \
       "$?|$(grep -c '^refused dc_st_kp_a_punch is entered by no comparison and no content or construction claim names it$' "$DIR/coverage-nopunch.out")" "1|1"
  fi
fi
took "build and demos (side by side)" "$t"

echo "== Full's route: the entries through the adapter, in job mode 1 =="
R=$DIR/route
if [ "$building" != yes ] || [ -z "$WADFILE" ]; then
  skipped "Full's route" "it needs the build and the IWAD"
elif [ ! -x "$ADAPTER_BIN" ]; then
  skipped "Full's route" "no adapter generator at $ADAPTER_BIN; set ADAPTER"
elif [ ! -f "$R/adapter.rc" ]; then
  ok "the route ran after the build" "no" "yes"
else
  ok "the adapter generates and links for the three entries" "$(cut -d' ' -f1 "$R/adapter.rc")" "rc=0"
  echo "  time adapter: $(cut -d' ' -f2 "$R/adapter.rc") s"
  reg=0; same=0
  for e in doom_core_input doom_core_step doom_core_render; do
    [ -s "$R/adapter/registry-$e.c" ] && reg=$((reg + 1))
    cmp -s "$R/adapter/registry-$e.c" "$R/adapter/registry-doom_core_input.c" && same=$((same + 1))
  done
  ok "  and every run wrote the same, non-empty registry" "$reg|$same" "3|3"
  cmpst() { # dir tic
    "$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$1/layout-$2.tsv" --a "$1/route-$2.bin" \
      --b "$1/original-$2.bin" --label-a route --label-b original --tic "$2" 2>&1
  }
  for d in $DEMOS; do
    tics=$(tics_of "$d")
    ok "route, $d: every tic runs, and every release is accepted" \
       "$(cut -d' ' -f1 "$R/$d.rc")|$(grep -c "^route-demo: $d $tics tic(s); .* 0 release(s) refused$" "$R/$d.err")" "rc=0|1"
    echo "  time route $d: $(cut -d' ' -f2 "$R/$d.rc") s ($(grep "^route-demo: $d " "$R/$d.err" | sed 's/.*; prepare/prepare/; s/;.*//'))"
    grep -v '^#' "$ROOT/tests/doom-core/fixtures/screens/$d.tsv" > "$R/$d.want"
    grep -v '^#' "$R/$d.screens" > "$R/$d.got"
    ok "  $d: every frame is the recorded one" "$(wc -l < "$R/$d.got" | tr -d ' ')|$(cmp -s "$R/$d.want" "$R/$d.got" && echo same)" "$tics|same"
    ok "  $d: the original reads every field at every checkpoint" \
       "$(cat "$R/$d.refrc")|$(grep -c 'unreadable$' "$R/$d.ref")|$(grep -c ' 0 unreadable$' "$R/$d.ref")" \
       "0|$(tr ',' '\n' < "$R/$d.ck" | wc -l | tr -d ' ')|$(tr ',' '\n' < "$R/$d.ck" | wc -l | tr -d ' ')"
    agree=0; n=0; first=""
    [ -s "$R/$d.ck" ] || first="no checkpoint list at $R/$d.ck"
    for c in $(tr ',' ' ' < "$R/$d.ck" 2>/dev/null); do
      n=$((n + 1))
      o=$(cmpst "$R/$d" "$c")
      case $o in "compare-state: "*" route and original agree at tic $c") agree=$((agree + 1)) ;; *) [ -n "$first" ] || first=$o ;; esac
    done
    ok "  $d: the state agrees at every checkpoint ($(cat "$R/$d.ck" 2>/dev/null))" "$agree${first:+ -- $first}" "$n"
    [ "$n" -gt 0 ] || ok "  $d: some checkpoint was compared" "$n" "more than 0"
    # THE SESSION-OPEN-ONLY CELLS, both sides' values at every checkpoint after
    # session open: a record, not a check -- an excluded cell stays in sight
    for c in $(tr ',' ' ' < "$R/$d.ck" 2>/dev/null); do
      [ "$c" = 0 ] && continue
      paste "$R/$d/route-$c.open-only.tsv" "$R/$d/original-$c.open-only.tsv" | awk -F"$TAB" -v c="$c" \
        '{ print "    OPEN_ONLY " $1 " before tic " c ": route " $2 ", original " $4 ($2 == $4 ? "" : " (differs)") }'
    done > "$R/$d.openonly"
    cat "$R/$d.openonly"
    echo "    OPEN_ONLY $d: $(grep -c 'differs' "$R/$d.openonly") of $(wc -l < "$R/$d.openonly" | tr -d ' ') value pair(s) differ"
  done
  # the rows: the three named cells at session open, and after it only the others
  d=${DEMOS%% *}
  L0=$R/$d/layout-0.tsv; L1=$R/$d/layout-500.tsv
  ok "  the session-open-only cells are compared at session open, and not after ($d)" \
     "$(grep -c -E '^renderer_(dc_srcres|ds_srcres|ds_srcbase)'"$TAB" "$L0")|$(grep -c -E '^renderer_(dc_srcres|ds_srcres|ds_srcbase)'"$TAB" "$L1")|$(grep -c -E '^renderer_dc_src(ofs|base)'"$TAB" "$L1")" "3|0|2"
  # the controls
  ok "  a route prepared in job mode 0 is refused before any frame" \
     "$(cat "$R/ctl-mode0.rc")|$(grep -c '^0' "$R/ctl-mode0.screens")|$(grep -c '^route-demo: refused (RouteError): the render entry is classified for job mode 1 and renderer_jobmode holds 0 at session open; the render is not called$' "$R/ctl-mode0.err")|$(grep -c '^route-demo: calls: step 0, render 0$' "$R/ctl-mode0.err")" "1|0|1|1"
  ok "  a 4 in the live mode cell is refused before the frame" \
     "$(cat "$R/ctl-mode4.rc")|$(grep -c 'renderer_jobmode holds 4 before frame 1; the render is not called' "$R/ctl-mode4.err")|$(grep -c '^route-demo: calls: step 1, render 0$' "$R/ctl-mode4.err")" "1|1|1"
  ok "  a pending rebirth is refused before the step, on the live cell" \
     "$(cat "$R/ctl-reborn.rc")|$(grep -c '^route-demo: refused (RebirthRefused): rebirth is not supported' "$R/ctl-reborn.err")|$(grep -c '^route-demo: calls: step 5, render 5$' "$R/ctl-reborn.err")" "1|1|1"
  # tics 0-100 only, against the recording's first 101 lines: the frames agree
  # up to tic 99 and differ at tic 100, line 101
  ok "  a planted health is a different frame from the recording, first at its tic" \
     "$(grep -v '^#' "$R/ctl-health.screens" | diff - "$R/ctl-health.want" | grep '^[0-9]' | tr '\n' ' ')" "101c101 "
  ok "  and a checkpoint difference named by field and tic" \
     "$(cmpst "$R/ctl-health" 100 | grep -c '^compare-state: value: game_pl_health\[0\] at tic 100: route has 5 and original has ')" 1
  ok "  a wrong session-open-only cell at session open is a difference" \
     "$(cmpst "$R/ctl-open" 0 | grep -c '^compare-state: value: renderer_dc_srcres\[0\] at tic 0: route has 0 and original has -1 (i64, byte [0-9]*)$')" 1
  "$RUBY" "$ROOT/tests/doom-core/graph-guard.rb" "$WADFILE" > "$R/graph-guard.out" 2>&1
  ok "a reference reads the program's objects and builds none (graph-guard.rb)" "$?|$(tail -n 1 "$R/graph-guard.out")" "0|graph-guard: all pass"
  if [ -f "$R/native.rc" ]; then
    ok "the playable program, through the entries (native.sh)" \
       "$(cut -d' ' -f1 "$R/native.rc")|$(awk '/^native: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" && $9 == "lane(s)" && $10 == "skipped" { n++ } END { print n + 0 }' "$R/native.out")" "rc=0|1"
    sed 's/^/    /' "$R/native.out"
    echo "  time native: $(cut -d' ' -f2 "$R/native.rc") s"
  else
    ok "the playable program's lane ran" "no" "yes"
  fi
  if [ -f "$R/bound-resources.rc" ]; then
    ok "the entries over resources bound to a read-only session image (bound-resources.sh)" \
       "$(cut -d' ' -f1 "$R/bound-resources.rc")|$(awk '/^bound-resources: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" && $9 == "lane(s)" && $10 == "skipped;" { n++ } END { print n + 0 }' "$R/bound-resources.out")" "rc=0|1"
    sed 's/^/    /' "$R/bound-resources.out"
    echo "  time bound-resources: $(cut -d' ' -f2 "$R/bound-resources.rc") s"
  else
    ok "the bound-resources lane ran" "no" "yes"
  fi
  if [ -f "$R/nsdiff.rc" ]; then
    ok "the scenario corpus through the compiled step entry (native-scenario-diff.sh)" \
       "$(cut -d' ' -f1 "$R/nsdiff.rc")|$(awk '/^native-scenario-diff: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" { n++ } END { print n + 0 }' "$R/nsdiff.out")" "rc=0|1"
    sed 's/^/    /' "$R/nsdiff.out"
    echo "  time native-scenario-diff: $(cut -d' ' -f2 "$R/nsdiff.rc") s"
    # THE TWO LANES, JOINED. The coverage part names the definitions the
    # scenarios enter and no demo does, with the scenarios that enter each;
    # this lane names the scenarios it ran against the compiled entry. Every
    # scenario in the first list must be in the second, or that definition is
    # compared in CORE-source execution alone and the claim of 0009's
    # clarification does not hold for it. Nothing here re-measures coverage: it
    # reads the two lanes' own output.
    if [ -f "$DIR/coverage.out" ] && [ -f "$R/nsdiff/ran.txt" ]; then
      sed -n 's/^ *step-coverage: entered by the scenarios and by no demo: [0-9]*: //p' "$DIR/coverage.out" |
        tr ' ' '\n' | sed -n 's/^[a-z_0-9]*(\(.*\))$/\1/p' | tr ',' '\n' | sort -u > "$R/nsdiff/need.txt"
      ok "  every scenario that enters a definition no demo enters ran against the compiled entry" \
         "$([ -s "$R/nsdiff/need.txt" ] && echo named)|$(comm -23 "$R/nsdiff/need.txt" "$R/nsdiff/ran.txt" | tr '\n' ' ')" \
         "named|"
      echo "  the corpus adds $(sed -n 's/^ *step-coverage: entered by the scenarios and by no demo: \([0-9]*\):.*/\1/p' "$DIR/coverage.out") definition(s) no demo enters, carried by $(wc -l < "$R/nsdiff/need.txt" | tr -d ' ') scenario(s), all of which ran here"
    else
      skipped "the coverage-to-compiled join" "it needs the step coverage record and this lane's run list"
    fi
  else
    ok "the scenario corpus' compiled lane ran" "no" "yes"
  fi
  if [ -f "$R/widths.rc" ]; then
    ok "the width table holds every measured value (widths.sh)" \
       "$(cut -d' ' -f1 "$R/widths.rc")|$(awk '/^widths: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $7 == "fail" && NF == 7 { n++ } END { print n + 0 }' "$R/widths.out")" "rc=0|1"
    sed 's/^/    /' "$R/widths.out"
    echo "  time widths: $(cut -d' ' -f2 "$R/widths.rc") s"
  else
    ok "the width table's lane ran" "no" "yes"
  fi
  s=$(date +%s)
  WAD="$WADFILE" REQUIRE_ALL="${REQUIRE_ALL:-}" sh "$ROOT/tests/doom-core/capacity.sh" "$DIR/capacity" > "$DIR/capacity.out" 2>&1
  ok "the work stack's capacity contract holds (capacity.sh)" \
     "$?|$(awk '/^capacity: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" { n++ } END { print n + 0 }' "$DIR/capacity.out")" "0|1"
  sed 's/^/    /' "$DIR/capacity.out"
  echo "  time capacity: $(( $(date +%s) - s )) s"
  "$RUBY" "$ROOT/tests/doom-core/mode-one.rb" "$WADFILE" > "$R/mode-one.out" 2>&1
  ok "the source conversion takes job mode 1 at session open only (mode-one.rb)" "$?|$(tail -n 1 "$R/mode-one.out")" "0|mode-one: all pass"
fi

echo "verify: $((pass + fail)) checked, $pass pass, $fail fail, $skip skipped; $(( $(date +%s) - T0 )) s"
if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then
  printf 'verify.sh: REQUIRE_ALL=1, and %s part(s) did not run:\n%s' "$skip" "$skips" >&2
  exit 1
fi
[ "$fail" -eq 0 ]
