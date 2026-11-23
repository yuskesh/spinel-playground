#!/bin/sh
#
# tests/doom-core/native-scenario-diff.sh — the scenario corpus through the COMPILED step entry.
#
#   LIB=... HEADERS=... WAD=... sh tests/doom-core/native-scenario-diff.sh DIR
#
# LIB is the shared object linking the three generated adapters and the kernel
# objects, HEADERS the adapter generator's directory: what
# tests/doom-core/verify.sh's route part builds (harness/artifacts.sh's
# dc_route_adapter and dc_adapter_link).
#
# THE PRINCIPLE (decision 0009): two hosts is not two coverages, and compiler
# confidence is not a substitute for executing the code under test. The
# compiled objects are played by DEMO1-3, which enter E1M5, E1M3 and E1M7;
# every definition the synthesised scenarios reach and no demo does was
# therefore compared in CORE-source execution only. This lane runs THE SAME
# CORPUS, scenario for scenario, against the compiled step entry, so that every
# definition exercised by the differential corpus is exercised and compared in
# both CORE-source and compiled-object execution.
#
# WHAT IT CHECKS
#   * the corpus it ran is exactly tests/doom-core/scenarios.rb's, by name: a
#     scenario added there and not run here is a coverage claim nobody kept
#   * every scenario: every compared tic agrees with the original evolving
#     beside it, at the cadence native-scenario-diff.rb prints
#   * a scenario declared to stop stops in the same tic on both sides, the
#     compiled side refusing through the adapter (CAPACITY), or -- for `reborn`
#     -- Full refusing before the call; and it does so in two runs
#   * TWO CONTROLS, each planting its own difference into the compiled side's
#     live state: a scalar, which the per-tic cadence must catch in its tic;
#     and a cell of an array nothing reads, which no tic can catch and the
#     final full comparison must -- the ARRAY-ONLY DIVERGENCE class this
#     cadence locates only at the end, witnessed rather than described
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: native-scenario-diff.sh DIR}
RUBY=${RUBY:-ruby}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
LIB=${LIB:?LIB is the shared object linking the adapters and the kernel objects}
HEADERS=${HEADERS:?HEADERS is the directory the adapter generator wrote}
PAR=${NSD_PAR:-4}
DRIVER=$ROOT/tests/doom-core/native-scenario-diff.rb
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
mkdir -p "$DIR" || exit 2

# The corpus, from the file that defines it (the driver's --corpus).
"$RUBY" "$DRIVER" --corpus > "$DIR/corpus.tsv" || exit 2
TAB=$(printf "\t")
field() { sed -n "s/^$1$TAB//p" "$DIR/corpus.tsv"; }
SCENARIOS=$(field names | tr ' ' '\n')
STOPS=$(field stops | tr ' ' '\n')
echo "== the scenario corpus through the compiled step entry =="
echo "  corpus: $(echo "$SCENARIOS" | wc -l | tr -d ' ') scenario(s), $(field tics) tic(s), over $(field maps); $(echo "$STOPS" | wc -l | tr -d ' ') of them stop"

s=$(date +%s)
i=0
for sc in $SCENARIOS; do
  ( "$RUBY" "$DRIVER" "$WADFILE" "$sc" "$LIB" "$HEADERS" "$DIR/$sc" > "$DIR/$sc.out" 2>&1
    echo "$?" > "$DIR/$sc.rc" ) &
  i=$((i + 1))
  [ "$((i % PAR))" -eq 0 ] && wait
done
# THE CONTROLS, both on `punch` and both over three tics: the run is not the
# claim, the planted difference is. The scalar is planted before tic 1 and the
# per-tic comparison must name it at tic 1; the array cell is a free mobj slot
# -- no thinker list holds it, so no tic reads it and no scalar reflects it.
( "$RUBY" "$DRIVER" "$WADFILE" punch "$LIB" "$HEADERS" "$DIR/ctl-scalar" --tics 3 \
    --plant game_pl_health=5@1 > "$DIR/ctl-scalar.out" 2>&1
  echo "$?" > "$DIR/ctl-scalar.rc" ) &
( "$RUBY" "$DRIVER" "$WADFILE" punch "$LIB" "$HEADERS" "$DIR/ctl-array" --tics 3 \
    --plant 'game_mobj_x[4000]=12345@1' > "$DIR/ctl-array.out" 2>&1
  echo "$?" > "$DIR/ctl-array.rc" ) &
wait
wall=$(( $(date +%s) - s ))
echo "  time the corpus and its controls: $wall s"

# THE CADENCE AND THE CLASS, from the run itself rather than from this file.
sed -n 's/^native-scenario-diff: cadence: /  cadence: /p;s/^native-scenario-diff: an ARRAY-ONLY/  an ARRAY-ONLY/p' \
  "$DIR/punch.out"

for sc in $SCENARIOS; do
  stops=no
  for t in $STOPS; do [ "$t" = "$sc" ] && stops=yes; done
  if [ "$stops" = yes ]; then
    # EVERY RUN OF IT STOPPED, and the two sides stopped together in each: the
    # second run is the one that takes the final full comparison, so a scenario
    # that stops before any tic completes has one run and a scenario that gets
    # past its first tic has two. Both are `every run stopped`.
    a=$(grep -c '^tic [0-9]*: both stopped -- the original raised ' "$DIR/$sc.out")
    b=$(grep -c '^native-scenario-diff: .* tic(s) ran, ' "$DIR/$sc.out")
    # and a full state somewhere: after the last tic that completed, or -- when
    # the first tic is the one that stops -- the state at session open, which
    # is then the only state the two sides ever shared.
    c=$(grep -c '^native-scenario-diff: full state .*field(s), 0 differ' "$DIR/$sc.out")
    ok "$sc: every run stops in the same tic on both sides; every compared tic and a full state agree" \
       "$(cat "$DIR/$sc.rc")|$([ "$a" = "$b" ] && [ "$a" -ge 1 ] && echo every-run-stopped)|$([ "$c" -ge 1 ] && echo full-state)|$(grep -c ' tic(s) compared, 0 disagreement(s); full state at ' "$DIR/$sc.out")" \
       "0|every-run-stopped|full-state|1"
  else
    ok "$sc: every compared tic agrees, and the full state at both ends" \
       "$(cat "$DIR/$sc.rc")|$(grep -c ' tic(s) compared, 0 disagreement(s); full state at ' "$DIR/$sc.out")|$(grep -c '^native-scenario-diff: full state after tic [0-9]*: [0-9]* field(s), 0 differ' "$DIR/$sc.out")" \
       "0|1|2"
  fi
  # WHAT THAT SCENARIO COVERED, not only that it passed: the run's own last
  # line, which says how many tics were compared and where the full states were
  # taken. The per-tic detail stays in $DIR/$sc.out.
  sed -n "s/^native-scenario-diff: $sc: /    /p" "$DIR/$sc.out"
done
# THE CORPUS CHECK: the runs that exist on disk, against the names the corpus
# defines. A scenario added to scenarios.rb and not run here -- or one whose
# run died before writing its status -- is a coverage claim nobody kept.
for f in "$DIR"/*.rc; do
  b=${f##*/}; b=${b%.rc}
  case $b in ctl-*) continue ;; esac
  echo "$b"
done | sort > "$DIR/ran.txt"
echo "$SCENARIOS" | sort > "$DIR/defined.txt"
ok "every scenario the corpus defines has a run here, and no other" \
   "$(cmp -s "$DIR/ran.txt" "$DIR/defined.txt" && echo same || diff "$DIR/defined.txt" "$DIR/ran.txt" | tr '\n' ' ')" "same"

echo "  -- the controls, each planting its own difference into the compiled side --"
# The first tic to disagree is the tic the plant was made before, and the
# scalar is named there. It is named in the tics after it as well: the two
# sides evolve independently, so a difference stays.
ok "a planted scalar is caught in its own tic, by the per-tic cadence" \
   "$(cat "$DIR/ctl-scalar.rc")|$(grep -m1 -o '^tic [0-9]*' "$DIR/ctl-scalar.out")|$([ "$(grep -c '^  game_pl_health: compiled 5, original 100$' "$DIR/ctl-scalar.out")" -ge 1 ] && echo named)" \
   "1|tic 1|named"
ok "a planted cell of an array nothing reads is caught by the full comparison alone" \
   "$(cat "$DIR/ctl-array.rc")|$(grep -c '^tic [0-9]*: [0-9]* disagreement(s)' "$DIR/ctl-array.out")|$(grep -c '^native-scenario-diff: full state after tic 0: [0-9]* field(s), 0 differ' "$DIR/ctl-array.out")|$(grep -c '^  game_mobj_x\[4000\]: compiled 12345, original 0 ' "$DIR/ctl-array.out")" \
   "1|0|1|1"

# WHAT THE RUN DID, not only what it concluded. Answering one question about
# this lane's own cost took three messages and a walk through the per-scenario
# files, and every quantity was already in them: one line per full comparison
# with its seconds, one prepare/bind/run line per run instance. The three that
# make the arithmetic work are the count, their sum, and THE FAN-OUT -- without
# which a reader multiplies comparisons by seconds and over-predicts the wall
# by the number of lanes running at once.
comps=$(cat "$DIR"/*.out 2>/dev/null | grep -c "^native-scenario-diff: full state ")
csecs=$(cat "$DIR"/*.out 2>/dev/null | grep "^native-scenario-diff: full state " |
        grep -oE "\([0-9]+\.[0-9]+ s\)" | tr -d "()s " | awk '{ t += $1 } END { printf "%.1f", t + 0 }')
serial=$(cat "$DIR"/*.out 2>/dev/null | grep "^native-scenario-diff: .* tic(s) ran, " |
         sed -n 's/.*prepare \([0-9.]*\) s, bind \([0-9.]*\) s, run \([0-9.]*\) s.*/\1 \2 \3/p' |
         awk '{ t += $1 + $2 + $3 } END { printf "%.0f", t + 0 }')
echo "  full comparisons: $comps, $csecs s summed, $PAR at a time; $serial s of work in $wall s of wall"
echo "native-scenario-diff: $((pass + fail)) checked, $pass pass, $fail fail, 0 skipped"
[ "$fail" -eq 0 ]
exit $?
