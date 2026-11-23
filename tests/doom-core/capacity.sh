#!/bin/sh
#
# tests/doom-core/capacity.sh — the work stack's capacity contract, witnessed.
#
#   WAD=... sh tests/doom-core/capacity.sh [DIR]
#
# Decision 0008's clarification of 2026-09-18 states the knot stack's contract
# for ANY declared capacity N:
#
#   required depth <= N  ->  CORE execution agrees with the reference
#   required depth  > N  ->  CORE refuses deterministically, without writing
#                            past the capacity
#
# so 256 is a configured capacity and not a claim that 256 bounds every legal
# execution. Three things must hold, and this checks the two that running code
# can show. (The third, agreement below the capacity, is step-diff.rb's and
# render-diff.rb's 0 disagreements over every tic of DEMO1-3 and the 19
# scenarios, which verify.sh runs.)
#
#   * EVERY PUSH IS CHECKED. tools/doom/knot-cps.rb emits the capacity check
#     and the push together, and refuses to write if any push in what it just
#     generated is not preceded by its check. A mutated generator that emits a
#     push without one must be refused.
#   * EXHAUSTION IS DETERMINISTIC AND WRITES NOTHING PAST THE END. The demo is
#     run at capacities below what it needs: at the floor, where the machine
#     refuses before its first frame, and PARTWAY, where the game has run for
#     over a thousand tics and has real state to damage. The refusal must name
#     the same tic every time, and the stack must still be exactly as long as
#     it was declared -- in CRuby a write past the end would grow the Array, so
#     its length is the evidence rather than a reading of the code.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:-${TMPDIR:-/tmp}/doom-core-capacity.$$}
RUBY=${RUBY:-ruby}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
DEMO=${CAPACITY_DEMO:-DEMO3}
REPEATS=${CAPACITY_REPEATS:-5}
# The capacities: the floor the machine refuses at, and one it survives for
# over a thousand tics before refusing. 21 frames runs this demo whole, which
# is the other half of the contract.
FLOOR=1
PARTWAY=18
WHOLE=21   # this demo's observed maximum is 20 frames; 21 fits it
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
summary() {
  echo "capacity: $((pass + fail)) checked, $pass pass, $fail fail, $skip skipped"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]; exit $?
}
mkdir -p "$DIR" || exit 2

echo "== every push carries its capacity check =="
# IN A TREE OF ITS OWN, so the checkout is not written to and the comparison is
# a file comparison rather than a question for git -- this lane runs from an
# exported tree, where there is no repository to ask.
mktree() { # dir
  rm -rf "$1"; mkdir -p "$1/tools/doom" "$1/examples/doom/core/src"
  cp -R "$ROOT/examples/doom/core/knot" "$1/examples/doom/core/knot"
  cp "$ROOT/examples/doom/core/src/stepknot.rb" "$1/examples/doom/core/src/stepknot.rb"
  cp "$ROOT/tools/doom/knot-sites.tsv" "$1/tools/doom/"
}
GEN=$DIR/generator
mktree "$GEN"
cp "$ROOT/tools/doom/knot-cps.rb" "$GEN/tools/doom/"
"$RUBY" "$GEN/tools/doom/knot-cps.rb" > "$DIR/gen.out" 2>&1
ok "the generator writes the machine and says every push is checked" \
   "$?|$(grep -c '^knot-cps: 203 push(es), each preceded by its capacity check, and the entry.s first frame checked$' "$DIR/gen.out")" "0|1"
ok "  and what it wrote is what the tree holds" \
   "$(cmp -s "$GEN/examples/doom/core/src/stepknot.rb" "$ROOT/examples/doom/core/src/stepknot.rb" && echo same)" "same"
# THE CONTROL: a generator that emits the push without the check must refuse to
# write. It is the generator that is mutated, not the generated file, because
# the claim is about what the generator can produce.
#
# IN A TREE OF ITS OWN. knot-cps.rb takes its inputs and its output path from
# its own location, so the mutant runs against a COPY of the knot source and
# writes -- if it writes at all, which is the point -- into that copy.
MUT=$DIR/mutant
mktree "$MUT"
sed 's|^    emit("  core_fail(:capacity)", ind)$|    # (control: the check is not emitted)|' \
  "$ROOT/tools/doom/knot-cps.rb" > "$MUT/tools/doom/knot-cps.rb"
cmp -s "$ROOT/tools/doom/knot-cps.rb" "$MUT/tools/doom/knot-cps.rb" && \
  { echo "  FAIL the control's edit changed nothing"; fail=$((fail + 1)); }
"$RUBY" "$MUT/tools/doom/knot-cps.rb" > "$DIR/unchecked.out" 2>&1
rc=$?
ok "a generator that emits a push without its check is refused, and writes nothing" \
   "$rc|$(grep -c 'has no capacity check before it' "$DIR/unchecked.out")|$(grep -c 'unchecked push(es); nothing written' "$DIR/unchecked.out")|$(cmp -s "$ROOT/examples/doom/core/src/stepknot.rb" "$MUT/examples/doom/core/src/stepknot.rb" && echo unwritten)" \
   "2|203|1|unwritten"

if [ ! -f "$WADFILE" ]; then
  echo "  SKIP the exhaustion witnesses: no IWAD at $WADFILE (set WAD)" >&2
  skip=$((skip + 1)); summary
fi

echo "== exhaustion: at the floor, and partway through $DEMO =="
# TICS, not the whole demo: the refusal is what this lane is about, and the run
# stops reporting after it. The demo running WHOLE at a capacity it fits in is
# the other half of the contract and is step-diff.rb's own lane in verify.sh,
# over every tic of DEMO1-3 -- it is not repeated here.
TICS=${CAPACITY_TICS:-1400}
run() { # frames out
  "$RUBY" "$ROOT/tests/doom-core/step-diff.rb" "$WADFILE" "$DEMO" "$TICS" --knot-frames "$1" > "$2" 2>&1
}
first_tic() { grep -m1 '^tic [0-9]*:' "$1" | cut -d: -f1; }
stack_line() { grep -m1 '^step-diff: knot stack ' "$1"; }

run "$FLOOR" "$DIR/floor.out"
rc=$?
ok "at $FLOOR frame(s) the machine refuses before its first frame" \
   "$rc|$(first_tic "$DIR/floor.out")|$([ "$(grep -c 'raised CoreFail: core_fail(:capacity)' "$DIR/floor.out")" -ge 1 ] && echo refused)" "1|tic 0|refused"
ok "  and nothing was written past the capacity" \
   "$(stack_line "$DIR/floor.out")" "step-diff: knot stack $FLOOR frame(s) = $((FLOOR * 21)) cell(s) declared, $((FLOOR * 21)) cell(s) after the run"

run "$PARTWAY" "$DIR/partway.out"
rc=$?
TIC=$(first_tic "$DIR/partway.out")
ok "at $PARTWAY frame(s) the game runs and then refuses, deep in the demo ($TIC)" \
   "$rc|$([ "$(grep -c 'raised CoreFail: core_fail(:capacity)' "$DIR/partway.out")" -ge 1 ] && echo refused)|$([ "${TIC#tic }" -gt 1000 ] && echo deep)" "1|refused|deep"
ok "  and nothing was written past the capacity there either" \
   "$(stack_line "$DIR/partway.out")" "step-diff: knot stack $PARTWAY frame(s) = $((PARTWAY * 21)) cell(s) declared, $((PARTWAY * 21)) cell(s) after the run"
# DETERMINISTIC: the same tic every time, not merely a refusal every time.
same=0
i=0
while [ "$i" -lt "$REPEATS" ]; do
  run "$PARTWAY" "$DIR/repeat-$i.out"
  [ "$(first_tic "$DIR/repeat-$i.out")" = "$TIC" ] && same=$((same + 1))
  i=$((i + 1))
done
ok "  and it refuses at the same tic in $REPEATS repeats" "$same" "$REPEATS"

run "$WHOLE" "$DIR/whole.out"
rc=$?
ok "at $WHOLE frame(s) the same run needs no refusal, and every tic agrees" \
   "$rc|$(grep -c ' tic(s), 0 disagreeing' "$DIR/whole.out")|$(grep -c 'core_fail(:capacity)' "$DIR/whole.out")" "0|1|0"
summary
