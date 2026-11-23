#!/usr/bin/env bash
# E083: the static rejection table for BUFFER platform externs -- profile-level
# lies (q*), kernel-level misuse of a declared surface (r*), and the controls
# that must keep compiling (c*).  E038/E040's discipline: a table with only
# rejections can be passed by a tool that rejects everything.
#
#   bash run_reject.sh   -> $RES/reject.tsv
#
# Ported from spinel-llvm 463d49dd docs/experiments/results/E083/run_reject.sh.
# The target runs are build_all.sh and run_gates.sh beside this script.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
mkdir -p "$RES"
W=$OUT/reject
PROF=$HERE/cortex-m33-zephyr-e083.yaml

fs_fresh_workdir "$W"; mkdir -p "$W/spinel"
cp "$FSDIR/spinel/freestanding.rb" "$W/spinel/"
cp "$HERE/reject/"*.rb "$W/"
cat > "$W/ok.rb" <<'EOF'
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
EOF

pass=0; fail=0
T=$RES/reject.tsv
printf 'id\texpect\tgot\tverdict\tpattern_or_note\n' > "$T"
emit() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$T"
         if [ "$4" = PASS ]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

refuse() {  # id, kernel, profile, stderr-pattern
  local id=$1 kern=$2 prof=$3 pat=$4 err rc
  err=$( (cd "$W" && "$MLIRGEN" "$kern" --freestanding --profile "$prof" \
          -o "$W/$id.mlir") 2>&1 ); rc=$?
  # Drop the note about the pre-T5 profile format, in the one spelling both
  # implementations share (decided 2026-09-07).
  err=$(printf '%s' "$err" | grep -v '^spinel-mlirgen: note: profile .* uses the pre-T5 format (deprecated; P008 Phase 2 canonicalizes the platform-first form); accepted unchanged$' || true)
  if [ $rc != 0 ] && printf '%s' "$err" | grep -q "$pat"; then
    emit "$id" REFUSE REFUSE PASS "$pat"
  elif [ $rc != 0 ]; then
    emit "$id" REFUSE "REFUSE(wrong reason)" FAIL \
      "$(printf '%s' "$err" | tail -1 | cut -c1-140)"
  else
    emit "$id" REFUSE ACCEPT FAIL "compiled"
  fi
}
accept() {  # id, kernel, profile
  local id=$1 kern=$2 prof=$3 err rc
  err=$( (cd "$W" && "$MLIRGEN" "$kern" --freestanding --profile "$prof" \
          -o "$W/$id.mlir") 2>&1 ); rc=$?
  # Drop the note about the pre-T5 profile format, in the one spelling both
  # implementations share (decided 2026-09-07).
  err=$(printf '%s' "$err" | grep -v '^spinel-mlirgen: note: profile .* uses the pre-T5 format (deprecated; P008 Phase 2 canonicalizes the platform-first form); accepted unchanged$' || true)
  if [ $rc = 0 ]; then emit "$id" ACCEPT ACCEPT PASS "control"
  else emit "$id" ACCEPT REFUSE FAIL \
    "$(printf '%s' "$err" | tail -1 | cut -c1-140)"; fi
}

# -- A. the profile is validated before anything is generated ---------------
refuse q1_buf_no_len     ok.rb "$HERE/reject/q1_buf_no_len.yaml"     "has no \`len\` after it"
refuse q2_len_first      ok.rb "$HERE/reject/q2_len_first.yaml"      "\`len\` must come directly after a buffer entry"
refuse q3_len_after_scalar ok.rb "$HERE/reject/q3_len_after_scalar.yaml" "\`len\` must come directly after a buffer entry"
refuse q4_bad_dir        ok.rb "$HERE/reject/q4_bad_dir.yaml"        "is not a buffer direction"
refuse q5_bad_elem       ok.rb "$HERE/reject/q5_bad_elem.yaml"       "is not a buffer element type"
refuse q6_three_elems    ok.rb "$HERE/reject/q6_three_elems.yaml"    "two entries"
refuse q7_buf_return     ok.rb "$HERE/reject/q7_buf_return.yaml"     "cannot be RETURNED"
refuse q8_bare_buf       ok.rb "$HERE/reject/q8_bare_buf.yaml"       "parameter type 'f64_buf' is not one of"

# Four patterns in B are the native emitter's wording. spinel-llvm wrote them
# against its retired Python generator ("The element type is the pointer's
# meaning", "the kernel's own :in / :out declaration does not license",
# "declared without a `:len`"); the emitter is byte-identical in both
# repositories. r3, r4 and r5 are the same refusals, reworded.
# r7 IS NOT: the kernel is refused -- its first buffer `d` has no `:len`, and
# that is the correct verdict -- but the emitter names the wrong reason, "buffer
# element :f64 is outside the freestanding subset" (f64 buffers are admitted;
# e077 runs them). The pattern pins today's message so that fixing the
# diagnostic shows up here; it records a defect, not a specification.
# -- B. kernel-level misuse of the declared buffer surface ------------------
refuse r1_scalar_for_buf r1_scalar_for_buf.rb "$PROF" "Only a buffer parameter of this kernel's own boundary"
refuse r2_buf_for_scalar r2_buf_for_scalar.rb "$PROF" "passing buffer \`d\` to platform extern 'grad_loss'"
refuse r3_elem_mismatch  r3_elem_mismatch.rb  "$PROF" "argument 1 of platform extern 'grad_loss' is a u8 buffer, but the profile declares f64"
refuse r4_dir_in_for_out r4_dir_in_for_out.rb "$PROF" "passes a \[:f64_buf, :in\], where the profile declares \[:f64_buf, :out\]"
refuse r5_dir_out_for_in r5_dir_out_for_in.rb "$PROF" "passes a \[:f64_buf, :out\], where the profile declares \[:f64_buf, :in\]"
refuse r6_float_len      r6_float_len.rb      "$PROF" "the profile declares it \`len\`"
refuse r7_lenless_buf    r7_lenless_buf.rb    "$PROF" "buffer element :f64 is outside the freestanding subset"

# -- C. controls ------------------------------------------------------------
accept c1_ok         c1_ok.rb         "$PROF"
accept c2_partial_len c2_partial_len.rb "$PROF"
accept c3_exact_dirs c3_exact_dirs.rb "$PROF"
# c4: an extern-free kernel still compiles under the buffer-extern profile,
# and a scalar-extern profile (E081's stored one) still accepts its kernel --
# the E081 surface did not move.  (The full E081 table re-runs in
# run_nonreg.sh; this row is the smoke form.)
accept c4_extern_free ok.rb "$PROF"

cat "$T"
echo "reject.tsv: pass=$pass fail=$fail"

# The byte comparison with spinel-llvm's recorded reject.tsv (reject_compare.rb)
# is an oracle and runs only on the user's instruction.
[ "$fail" = 0 ] || exit 1
