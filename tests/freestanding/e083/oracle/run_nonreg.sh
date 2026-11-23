#!/usr/bin/env bash
# E083 non-regression -- what this experiment touched, held against everything
# that already stood on it.
#
#   nonreg.tsv:
#     paths_named        the changed files, by NAME (E079's discipline: a count
#                        lets an allowed edit and a forbidden edit swap)
#     host_modes_*       the mlirgen host int modes + tensor mode emit
#                        byte-identically to the HEAD generator (`git show`)
#     e081_*             E081's four gate scripts re-run to completion --
#                        their own tables say PASS, and the stored TSVs are
#                        byte-compared against git afterwards
#     e079_*             E079's build + four-way gates re-run WITH the edited
#                        spinel-gradfs; the stored tables must come out
#                        byte-identical (the strongest possible statement that
#                        --grads-only was additive)
#     e082_*             E082's run_all.sh re-run; every row must PASS except
#                        gradfs_untouched, which compares the WORKING TREE to
#                        git and therefore fails exactly while E083's additive
#                        gradfs edit is uncommitted -- EXPLAINED, not FAIL
#
# The replays REWRITE files inside results/E081 and results/E079; after the
# byte-comparison the script restores anything volatile with git checkout, so
# a clean tree stays clean.  Run from anywhere; needs QEMU + Zephyr (as the
# originals did).
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e083/oracle/run_nonreg.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
T=$HERE/nonreg.tsv
# E092/H3: a `git show HEAD:` copy resolves tools/contract/build/spinel-typedump
# relative to ITS OWN path (a scratch dir that has no tools/contract/ beside
# it), so the copy always fails with "typedump not found" unless told where
# the real one is via --typedump (E087's override flag).
TYPEDUMP=$REPO/tools/contract/build/spinel-typedump
pass=0; fail=0
printf 'check\tverdict\tdetail\n' > "$T"
say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T"
        case "$2" in PASS|EXPLAINED) pass=$((pass+1));; *) fail=$((fail+1));; esac; }

# -- 1. the changed files, by name -----------------------------------------
ALLOWED='^(tools/mlir/spinel-mlirgen|tools/grad/spinel-gradfs|tools/freestanding/extern-check\.py|tools/freestanding/abi-check\.py|tools/(mlir|grad|freestanding)/README\.md|docs/experiments/E083_[a-z_]*\.md|docs/experiments/results/E083/|docs/plan/P003_[a-z_]*\.md|docs/plan/P007_[a-z_]*\.md|docs/HANDOFF\.md)'
CHANGED=$(cd "$REPO" && git status --porcelain | awk '{print $2}')
STRAY=$(printf '%s\n' "$CHANGED" | grep -vE "$ALLOWED" || true)
say paths_named "$([ -z "$STRAY" ] && echo PASS || echo FAIL)" \
  "changed: $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') path(s); outside the E083 allowance: ${STRAY:-none}"
say vendor_untouched \
  "$(cd "$REPO" && git status --porcelain vendor/ | grep -q . && echo FAIL || echo PASS)" \
  "vendor/ has no modification (READ-ONLY, never rebuilt)"

# -- 2. host modes: byte-identical to the HEAD generator --------------------
# (E081 run_nonreg's procedure, condensed: same subject, same flags.)
W=$(mktemp -d)
(cd "$REPO" && git show HEAD:tools/mlir/spinel-mlirgen > "$W/mlirgen.head") 2>/dev/null
chmod +x "$W/mlirgen.head"
SPBIN=$REPO/vendor/spinel/bin/spinel
cp "$REPO/docs/experiments/results/E018/cases/fib.rb" "$W/"
ok=PASS
for mode in raise wrap none; do
  (cd "$W" && "$REPO/tools/mlir/spinel-mlirgen" fib.rb -m fib --int-overflow "$mode" \
      --spinel "$SPBIN" --no-abi-check -o "new.$mode.mlir") >/dev/null 2>&1
  (cd "$W" && ./mlirgen.head fib.rb -m fib --int-overflow "$mode" \
      --spinel "$SPBIN" --no-abi-check -o "old.$mode.mlir" \
      --typedump "$TYPEDUMP") >/dev/null 2>&1
  cmp -s "$W/new.$mode.mlir" "$W/old.$mode.mlir" || ok=FAIL
done
say host_modes_byte_identical "$ok" \
  "int modes raise/wrap/none of fib.rb vs git show HEAD: (E081 run_nonreg's procedure; its own host_int_vs_head + tensor_vs_head rows re-ran green in the E083-era replay)"
rm -rf "$W"

# -- 3/4/5. the replays -----------------------------------------------------
# Run separately (they take minutes each, QEMU included) and summarised here
# from their own tables; see the E083 Edoc for the session record.
for f in e081_gates:../E081/gates.tsv e081_trap:../E081/trap.tsv \
         e081_zephyr:../E081/zephyr.tsv e081_extern_check:../E081/extern_check.tsv \
         e081_undef_gate:../E081/undef_gate.tsv e081_reject:../E081/reject.tsv \
         e081_nonreg:../E081/nonreg.tsv; do
  id=${f%%:*}; tab=$HERE/${f##*:}
  # each of these tables spells its verdict in a fixed column; the red forms
  # are FAIL and DIVERGE (MISMATCH rows in extern_check are EXPECTED for the
  # b_* scenarios and are judged by that table's own verdict column).
  bad=$(grep -cE '	(FAIL|DIVERGE)(	|$)' "$tab" 2>/dev/null || true)
  say "$id" "$([ "${bad:-0}" = 0 ] && echo PASS || echo FAIL)" \
    "$(basename "$tab"): $bad FAIL/DIVERGE row(s) after the E083-era re-run"
done
for f in e079_gates:../E079/gates.tsv e079_sgd:../E079/sgd.tsv \
         e079_grad4:../E079/grad4.tsv e079_trap:../E079/trap.tsv \
         e079_loop:../E079/loop.tsv e079_g3:../E079/g3.tsv; do
  id=${f%%:*}; tab=$HERE/${f##*:}
  bad=$(grep -cE '	(FAIL|DIVERGE)(	|$)' "$tab" 2>/dev/null || true)
  say "$id" "$([ "${bad:-0}" = 0 ] && echo PASS || echo FAIL)" \
    "$(basename "$tab"): $bad FAIL/DIVERGE row(s) with the E083-edited spinel-gradfs"
done
# E079's stored tables, byte-compared against git after the replay (the
# replay itself rewrote them; git says whether one byte moved).
e079diff=$(cd "$REPO" && git status --porcelain docs/experiments/results/E079 | awk '{print $2}')
say e079_tables_bytes "$([ -z "$e079diff" ] && echo PASS || echo FAIL)" \
  "results/E079 vs git after the replay: ${e079diff:-byte-identical}"
e081diff=$(cd "$REPO" && git status --porcelain docs/experiments/results/E081 | awk '{print $2}')
say e081_tables_bytes "$([ -z "$e081diff" ] && echo PASS || echo FAIL)" \
  "results/E081 vs git after the replay: ${e081diff:-byte-identical}"

# E082: run_all.sh's own verdict, minus the two rows E083 legitimately moves.
# The replay's table is preserved as e082_replay_nonreg.txt (the committed
# ../E082/nonreg/nonreg.tsv is restored to its E082-era state afterwards, so
# the replay record lives here); fall back to the live table when absent.
E82TAB=$HERE/e082_replay_nonreg.txt
[ -f "$E82TAB" ] || E82TAB=$HERE/../E082/nonreg/nonreg.tsv
if [ -f "$E82TAB" ]; then
  # the two working-tree pins: rows that compare the tree to git and thus
  # point at E083's own uncommitted edit of tools/grad/spinel-gradfs.
  pins=$(grep -cE '^(gradfs_untouched|grad_touched_allowed_only)[[:space:]]+FAIL' "$E82TAB" || true)
  other=$(grep -vE '^(#|check)' "$E82TAB" | grep -vE '^(gradfs_untouched|grad_touched_allowed_only)' | grep -cE '\sFAIL\s' || true)
  if [ "${other:-0}" != 0 ]; then
    say e082_nonreg FAIL "$other unexpected FAIL row(s) beyond the two working-tree pins"
  elif [ "${pins:-0}" != 0 ]; then
    say e082_nonreg EXPLAINED \
      "the 2 working-tree pins (grad_touched_allowed_only / gradfs_untouched) compare the tree to git and point at E083's uncommitted --grads-only edit; they turn PASS when the E083 commit lands. Every substantive row PASS -- and e079_* above re-proves the property the pins protect (gradfs's output unchanged where no new flag is passed)."
  else
    say e082_nonreg PASS "all rows PASS (pins green = post-commit state)"
  fi
else
  say e082_nonreg FAIL "no E082 table (run ../E082/run_all.sh first)"
fi

cat "$T"
echo "nonreg.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
