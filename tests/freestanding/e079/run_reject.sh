#!/usr/bin/env bash
# E079 rejection table -- the broken shapes a calibration loop actually takes,
# with the controls in the same table (a tool that refuses everything passes a
# table of refusals and fails one that also holds things which must build).
# Ported from spinel-llvm 463d49dd docs/experiments/results/E079/run_reject.sh.
#
# The g* rows are freestanding_grad_def's own gate, through spinel-fs-grad (the
# native generator that replaced spinel-gradfs, which spinel-llvm had retired and
# so wrote these rows as ABSENT); the b* rows are E077's freestanding gates,
# through spinel-fs-emit. Not run: the byte comparison of the table with the
# recorded one (reject_compare.rb), a golden from another implementation.
#
#   bash run_reject.sh    -> $RES/reject.tsv
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_enzyme
W=$OUT/reject
PROFILE=${PROFILE:-$FSDIR/profiles/wasm32-worker.yaml}
mkdir -p "$RES"
fs_fresh_workdir "$W"; mkdir -p "$W/b" "$W/spinel"
cp "$FSDIR/spinel/freestanding.rb" "$REPO/tools/grad/spinel/grad_freestanding.rb" "$W/spinel/"
cp "$HERE"/reject/*.rb "$W/"

row() {  # $1=id  $2=tool  $3=expect(REFUSE|ACCEPT)
  local id=$1 tool=$2 expect=$3 rc msg verdict
  if [ "$tool" = fs-grad ]; then
    msg=$( (cd "$W" && "$FSGRAD" "$id.rb" --profile "$PROFILE" -o "$W/b" \
             --tag "$id" --enzyme "$ENZYME" 2>&1 >/dev/null) && echo "rc=0" || true )
  else
    msg=$( (cd "$W" && "$MLIRGEN" "$id.rb" --freestanding --profile "$PROFILE" \
             -o "$W/b/$id.o" 2>&1 >/dev/null) && echo "rc=0" || true )
  fi
  case "$msg" in *rc=0) rc=0 ;; *) rc=1 ;; esac
  # The profile reader's note about the pre-T5 format is not the diagnostic.
  msg=$(printf '%s' "$msg" | grep -v '^spinel-mlirgen: note: profile .* uses the pre-T5 format' || true)
  local got=ACCEPT; [ "$rc" = 0 ] || got=REFUSE
  verdict=PASS; [ "$got" = "$expect" ] || verdict=FAIL
  msg=$(printf '%s' "${msg%rc=0}" | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-190)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$tool" "$expect" "$got" "$verdict" "$msg"
}

# exports_row <id> <symbol>: a row of its own, that fs-emit's <id>.o defines <symbol>
exports_row() {
  local verdict=FAIL
  "$NM" --defined-only --extern-only "$W/b/$1.o" 2>/dev/null | awk '{print $3}' | grep -qx "$2" && verdict=PASS
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1.exports" nm "defines $2" "$( [ "$verdict" = PASS ] && echo "defines $2" || echo missing)" "$verdict" ""
}

{
  printf 'id\ttool\texpect\tgot\tverdict\tdiagnostic\n'
  # --- A. the gradient declaration ---------------------------------------
  row g01_no_boundary     fs-grad REFUSE
  row g02_f32_return      fs-grad REFUSE
  row g03_scalar_wrt      fs-grad REFUSE
  row g03_f32_buf         fs-grad REFUSE
  row g04_unknown_wrt     fs-grad REFUSE
  row g05_forward         fs-grad REFUSE
  row g06_out_buffer      fs-grad REFUSE
  row g07_bad_tol         fs-grad REFUSE
  row g08_duplicate       fs-grad REFUSE
  row g09_empty_wrt       fs-grad REFUSE
  row g12_unknown_kw      fs-grad REFUSE
  # --- B. the calibration loop's own shapes, through E077's gates ---------
  row b01_write_in_buffer fs-emit REFUSE
  row b02_reassign_len    fs-emit REFUSE
  row b03_allocating_loss fs-emit REFUSE
  # b4/b5: what stops the SGD loop itself from being a freestanding kernel.
  row b04_loop_calls_adjoint fs-emit REFUSE
  # Decision 0044 admits b5: a helper takes the buffers its caller lends it,
  # so the object builds and exports the entry (the values of lent buffers
  # are run by tests/fs-helper-buffers). oracle/tables/reject.tsv still says
  # REFUSE; it is the recorded predecessor table and runs only under
  # ALLOW_ORACLE.
  row b05_buffer_to_callee   fs-emit ACCEPT
  exports_row b05_buffer_to_callee spinel_calibrate2
  # --- C. controls: the same things done the way that is allowed ----------
  row c01_control_ok      fs-grad ACCEPT
  row c01_control_ok      fs-emit ACCEPT
} > "$RES/reject.tsv"

cut -c1-160 "$RES/reject.tsv"
n=$(awk -F'\t' 'NR>1 && $5!="PASS"' "$RES/reject.tsv" | wc -l | tr -d ' ')
echo "reject.tsv: $(( $(wc -l < "$RES/reject.tsv") - 1 )) rows, $n unexpected"
[ "$n" = 0 ]
