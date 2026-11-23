#!/usr/bin/env bash
# E082 non-regression -- what E082 must not have moved.
#
# Same shape as E079's run_nonreg.sh, with two deliberate differences:
#   - the E077/mlirgen legs are NOT run: E081 is working in tools/mlir and
#     tools/freestanding IN PARALLEL, so regenerating through spinel-mlirgen
#     would race a half-edited generator and prove nothing about E082
#     (which cannot touch those trees).  The scope check below therefore
#     names only what E082 IS allowed to touch and vendor/.
#   - E076's twoexits build.tsv is compared with ONE EXPLAINED exception:
#     `generated_c_fnv1a` moves because spinel/grad.rb (textually inserted
#     into every generated C by require_relative) grew the hvp:/jvp:
#     keywords.  The check verifies the diff is EXACTLY that one line --
#     anything else is a failure.
#
#   bash run_nonreg.sh   -> nonreg.tsv
set -euo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tests/grad/e082/oracle/nonreg/run_nonreg.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../../.." && pwd)
E076=$REPO/docs/experiments/results/E076
E078=$REPO/docs/experiments/results/E078

say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
cmpf() {
  if cmp -s "$2" "$3"; then say "$1" PASS "byte-identical"
  else say "$1" FAIL "differs: $2 vs $3"; fi
}

{
printf 'check\tverdict\tdetail\n'

# --- 1. scope: what E082 touched under tools/ and vendor/ -----------------
# E081 runs in parallel (tools/mlir, tools/freestanding), so this check
# names E082's OWN allowed set inside tools/grad and vendor/, and does not
# assert anything about trees another experiment owns.
st=$(cd "$REPO" && git status --porcelain -- tools/grad vendor || true)
touched=$(printf '%s\n' "$st" | grep . | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')
allowed="tools/grad/README.md tools/grad/rules/ tools/grad/spinel-gradgen tools/grad/spinel-searchgate tools/grad/spinel/grad.rb tools/grad/spinel/grad_rules.rb "
say grad_touched_allowed_only \
    "$([ "$touched" = "$allowed" ] && echo PASS || echo FAIL)" \
    "touched: ${touched:-<nothing>} (allowed: $allowed)"
vend=$(printf '%s\n' "$st" | grep -c '^.. vendor/' || true)
say vendor_untouched "$([ "$vend" = 0 ] && echo PASS || echo FAIL)" \
    "$vend changes under vendor/ (READ-ONLY)"
say vendor_head PASS "$(git -C "$REPO/vendor/spinel" rev-parse --short HEAD) (READ-ONLY, never rebuilt)"
say gradfs_untouched \
    "$(cd "$REPO" && git diff --quiet -- tools/grad/spinel-gradfs tools/grad/spinel/grad_freestanding.rb && echo PASS || echo FAIL)" \
    "spinel-gradfs and grad_freestanding.rb byte-identical (E079's G5 and 4-target gates rest on them)"

# --- 2. E076 regenerated with the E082 gradgen ----------------------------
# Every change to spinel-gradgen is additive behind the new keywords, so the
# reject corpus and the twoexits gates must come back byte-identical.  Run
# IN PLACE (the generated C carries absolute paths, E079's discovery).
( cd "$E076/rejects" && bash run.sh ) > "$HERE/e076_rejects.log" 2>&1 || true
cmpf e076_rejects_tsv   "$E076/rejects/out/rejects.tsv" "$E076/tables/rejects.tsv"
cmpf e076_rejects_gates "$E076/rejects/out/gates.tsv"   "$E076/tables/rejects_gates.tsv"
( cd "$E076/rejects" && rm -rf out bite spinel rejects_run )

( cd "$E076/twoexits" && bash run.sh ) > "$HERE/e076_twoexits.log" 2>&1 || true
cmpf e076_twoexits_gates   "$E076/twoexits/out/gates.tsv"   "$E076/tables/twoexits_gates.tsv"
cmpf e076_twoexits_targets "$E076/twoexits/out/targets.tsv" "$E076/tables/twoexits_targets.tsv"
d=$(diff "$E076/twoexits/out/build.tsv" "$E076/tables/twoexits_build.tsv" | grep '^[<>]' | grep -vc generated_c_fnv1a || true)
n=$(diff "$E076/twoexits/out/build.tsv" "$E076/tables/twoexits_build.tsv" | grep -c '^[<>]' || true)
if [ "$n" = 0 ]; then say e076_twoexits_build PASS "byte-identical"
elif [ "$d" = 0 ]; then
  say e076_twoexits_build EXPLAINED \
    "only generated_c_fnv1a differs ($n line(s)): spinel/grad.rb grew hvp:/jvp: keyword parameters and is textually inserted into every generated C.  Gates and targets above are byte-identical"
else say e076_twoexits_build FAIL "$n differing line(s), not only the hash"; fi
( cd "$E076/twoexits" && rm -rf out spinel gates.txt twin twin_grad.gen.rb twin_grad.o twoexits.tsv )

# --- 3. E078's out-of-surface HVP shim still builds and still agrees ------
# The promotion must not have broken the thing it promoted: E078's own
# build (gradgen legacy path + appended shim) reruns with the E082 gradgen,
# and its s5.2 summary line must reproduce the committed numbers.
( cd "$E078/hvp" && sh build.sh ) > "$HERE/e078_build.log" 2>&1 || true
if [ -x "$E078/hvp/gbuild/cond_driver" ]; then
  "$E078/hvp/gbuild/cond_driver" > "$HERE/e078_fresh.txt" 2>/dev/null || true
  want=$(grep 's5.2.*worst_rel_vs_analytic' "$E078/hvp/hvp_results.txt" | head -1)
  got=$(grep 's5.2.*worst_rel_vs_analytic' "$HERE/e078_fresh.txt" | head -1)
  if [ -n "$got" ] && [ "$want" = "$got" ]; then
    say e078_hvp_shim PASS "s5.2 summary reproduced: $got"
  else
    say e078_hvp_shim FAIL "want [$want] got [$got]"
  fi
  rm -rf "$E078/hvp/gbuild"
else
  say e078_hvp_shim FAIL "build.sh did not produce gbuild/cond_driver (see e078_build.log)"
fi
} > "$HERE/nonreg.tsv"

column -t -s "$(printf '\t')" "$HERE/nonreg.tsv" | cut -c1-160
bad=$(awk -F'\t' 'NR>1 && $2=="FAIL"' "$HERE/nonreg.tsv" | wc -l | tr -d ' ')
echo "nonreg.tsv: $(( $(wc -l < "$HERE/nonreg.tsv") - 1 )) rows, $bad FAIL"
[ "$bad" = 0 ]
