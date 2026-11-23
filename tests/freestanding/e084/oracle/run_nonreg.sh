#!/usr/bin/env bash
# E084 non-regression -- what this experiment touched, held against everything
# that already stood on it.
#
#   nonreg.tsv:
#     paths_named          the changed files, by NAME (E079's discipline)
#     vendor_untouched     vendor/ has no modification
#     parallel_lanes       tools/mlir + tools/freestanding + tools/shader are
#                          UNTOUCHED (E085 runs in parallel; E084's allowance
#                          is tools/grad and its own results only)
#     e079_*               E079's build + four-way gates re-run WITH the
#                          E084-edited spinel-gradfs; the stored tables must
#                          come out byte-identical (hvp: not declared => the
#                          new code is dead, provably)
#     e083_*               E083's build + gates + reject re-run the same way
#                          (the E083 kernel has no hvp: either), plus its own
#                          run_nonreg.sh (whose paths_named row pins E083's
#                          change window and must now point at exactly E084's
#                          allowance -- EXPLAINED, recorded, restored)
#     e082_*               E082's run_all.sh re-run; every row must PASS
#                          except the two working-tree pins that point at
#                          E084's uncommitted tools/grad edits -- EXPLAINED
#
# The replays REWRITE files inside results/E079, E083 and E082; after the
# byte-comparison the script restores anything volatile with git checkout,
# so a clean tree stays clean.  Needs QEMU + Zephyr (as the originals did).
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e084/oracle/run_nonreg.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
export SCRATCH
T=$HERE/nonreg.tsv
pass=0; fail=0
printf 'check\tverdict\tdetail\n' > "$T"
say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T"
        case "$2" in PASS|EXPLAINED) pass=$((pass+1));; *) fail=$((fail+1));; esac; }

# -- 1. the changed files, by name -----------------------------------------
ALLOWED='^(tools/grad/spinel-gradfs|tools/grad/spinel/grad_freestanding\.rb|tools/grad/README\.md|docs/experiments/E084_[a-z_]*\.md|docs/experiments/results/E084/|docs/plan/P007_[a-z_]*\.md|docs/HANDOFF\.md)'
CHANGED=$(cd "$REPO" && git status --porcelain | awk '{print $2}')
STRAY=$(printf '%s\n' "$CHANGED" | grep -vE "$ALLOWED" || true)
say paths_named "$([ -z "$STRAY" ] && echo PASS || echo FAIL)" \
  "changed: $(printf '%s\n' "$CHANGED" | grep -c . ) path(s); outside the E084 allowance: ${STRAY:-none}"
say vendor_untouched \
  "$(cd "$REPO" && git status --porcelain vendor/ | grep -q . && echo FAIL || echo PASS)" \
  "vendor/ has no modification (READ-ONLY, never rebuilt)"
say parallel_lanes \
  "$(cd "$REPO" && git status --porcelain tools/mlir tools/freestanding tools/shader 2>/dev/null | grep -q . && echo FAIL || echo PASS)" \
  "tools/mlir + tools/freestanding + tools/shader untouched (E085 parallel discipline)"

restore_and_report() {  # $1 = results dir, $2 = row id, $3 = pin-table regex (optional)
  # $3 names the replayed experiment's OWN nonreg pin table: the replay is
  # EXPECTED to rewrite it while E084's edits are uncommitted (its rows pin
  # the working tree), it is captured as e08x_replay_nonreg.txt and judged in
  # its own row above -- so its byte-diff here is the pin, not a regression.
  local dir="docs/experiments/results/$1" id=$2 pin=${3:-'^$'}
  local diffs tsvdiffs
  diffs=$(cd "$REPO" && git status --porcelain "$dir" | awk '{print $2}')
  tsvdiffs=$(printf '%s\n' "$diffs" | grep -E '\.(tsv|h)$' | grep -vE "$pin" || true)
  if [ -z "$diffs" ]; then
    say "$id" PASS "every stored file byte-identical after the replay"
  elif [ -z "$tsvdiffs" ]; then
    say "$id" PASS "tables byte-identical (pin tables excepted, judged in their own rows); volatile files restored: $(printf '%s' "$diffs" | tr '\n' ' ')"
  else
    say "$id" FAIL "stored tables moved: $(printf '%s' "$tsvdiffs" | tr '\n' ' ')"
  fi
  (cd "$REPO" && git checkout -q -- "$dir") || true
}

table_row() {  # $1 = id, $2 = table path, summarise FAIL/DIVERGE
  local bad
  bad=$(grep -cE '	(FAIL|DIVERGE|RED)(	|$)' "$2" 2>/dev/null || true)
  say "$1" "$([ "${bad:-0}" = 0 ] && echo PASS || echo FAIL)" \
    "$(basename "$2"): ${bad:-0} FAIL/DIVERGE row(s) after the E084-era re-run"
}

# -- 2. E079 with the edited gradfs -----------------------------------------
echo "== replay: E079 (edited spinel-gradfs, no hvp declared) =="
( cd "$HERE/../E079" && bash build_all.sh && bash run_gates.sh ) \
    > "$SCRATCH/e084/replay_e079.log" 2>&1
say e079_replay_ran "$([ $? = 0 ] && echo PASS || echo FAIL)" \
  "build_all + run_gates completed (log: scratch/e084/replay_e079.log)"
for f in gates.tsv grad4.tsv g3.tsv trap.tsv loop.tsv; do
  table_row "e079_$(basename "$f" .tsv)" "$HERE/../E079/$f"
done
restore_and_report E079 e079_tables_bytes

# -- 3. E083 with the edited gradfs -----------------------------------------
echo "== replay: E083 (edited spinel-gradfs, --grads-only, no hvp declared) =="
( cd "$HERE/../E083" && bash build_all.sh && bash run_gates.sh && bash run_reject.sh ) \
    > "$SCRATCH/e084/replay_e083.log" 2>&1
say e083_replay_ran "$([ $? = 0 ] && echo PASS || echo FAIL)" \
  "build_all + run_gates + run_reject completed (log: scratch/e084/replay_e083.log)"
for f in gates.tsv e079.tsv loop.tsv trap.tsv surface.tsv reject.tsv determinism.tsv abi.tsv extern_check.tsv; do
  table_row "e083_$(basename "$f" .tsv)" "$HERE/../E083/$f"
done
# E083's own nonreg (paths/host-modes/summaries).  Its paths_named row pins
# E083's change window, so on E084's tree it must FAIL by naming exactly the
# E084 allowance -- that is the pin doing its job, recorded and restored.
( cd "$HERE/../E083" && bash run_nonreg.sh ) \
    > "$SCRATCH/e084/replay_e083_nonreg.log" 2>&1 || true
cp "$HERE/../E083/nonreg.tsv" "$HERE/e083_replay_nonreg.txt" 2>/dev/null || true
pins=$(grep -cE '^paths_named\tFAIL' "$HERE/e083_replay_nonreg.txt" || true)
strayrow=$(awk -F'\t' '$1=="paths_named"{print $3}' "$HERE/e083_replay_nonreg.txt")
others=$(grep -vE '^(check|paths_named)' "$HERE/e083_replay_nonreg.txt" | grep -cE '\tFAIL\t' || true)
if [ "${others:-0}" != 0 ]; then
  say e083_nonreg FAIL "$others unexpected FAIL row(s) beyond the paths pin"
elif [ "${pins:-0}" != 0 ]; then
  if printf '%s' "$strayrow" | grep -qE 'tools/(mlir|freestanding|shader)'; then
    say e083_nonreg FAIL "the paths pin names a forbidden lane: $strayrow"
  else
    say e083_nonreg EXPLAINED \
      "paths_named pins E083's change window and now names E084's own (allowed) edits; every other row PASS. Recorded as e083_replay_nonreg.txt"
  fi
else
  say e083_nonreg PASS "all rows PASS (post-commit state)"
fi
restore_and_report E083 e083_tables_bytes "results/E083/nonreg\.tsv$"

# -- 4. E082 run_all --------------------------------------------------------
echo "== replay: E082 run_all =="
( cd "$HERE/../E082" && bash run_all.sh ) \
    > "$SCRATCH/e084/replay_e082.log" 2>&1 || true
cp "$HERE/../E082/nonreg/nonreg.tsv" "$HERE/e082_replay_nonreg.txt" 2>/dev/null || true
pins=$(grep -cE '^(gradfs_untouched|grad_touched_allowed_only)[[:space:]]+FAIL' "$HERE/e082_replay_nonreg.txt" || true)
other=$(grep -vE '^(#|check)' "$HERE/e082_replay_nonreg.txt" | grep -vE '^(gradfs_untouched|grad_touched_allowed_only)' | grep -cE '\sFAIL\s' || true)
if [ "${other:-0}" != 0 ]; then
  say e082_nonreg FAIL "$other unexpected FAIL row(s) beyond the two working-tree pins"
elif [ "${pins:-0}" != 0 ]; then
  say e082_nonreg EXPLAINED \
    "the working-tree pins point at E084's uncommitted tools/grad edits (spinel-gradfs + grad_freestanding.rb); they turn PASS when the E084 commit lands. Every substantive row PASS -- and e079_*/e083_* above re-prove the pinned property dynamically (gradfs output unchanged where hvp: is not declared)."
else
  say e082_nonreg PASS "all rows PASS (pins green = post-commit state)"
fi
# the stage tables directly (run_all's `set -e` stops before the tables/
# copy when the nonreg pins are red, exactly as in the E083-era replay)
for f in hvp/e082_hvp_gates.tsv hvp/e082_newton.tsv rules/e082_rules_gates.tsv searchgate/e082_searchgate_gates.tsv; do
  table_row "e082_$(basename "$f" .tsv | sed 's/^e082_//')" "$HERE/../E082/$f"
done
restore_and_report E082 e082_tables_bytes "results/E082/(nonreg/nonreg|tables/e082_nonreg)\.tsv$"

cat "$T"
echo "nonreg.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
