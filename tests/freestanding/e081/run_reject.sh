#!/usr/bin/env bash
# E081: the static rejection table -- profile-level lies, kernel-level misuse,
# and the controls that must keep compiling (E038/E040's discipline: a table
# with only rejections can be passed by a tool that rejects everything).
#
#   bash run_reject.sh   -> reject.tsv
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
mkdir -p "$RES"
W=$OUT/reject
PROF=$HERE/cortex-m33-zephyr-e081.yaml

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
  if [ $rc = 0 ]; then emit "$id" ACCEPT ACCEPT PASS "control"
  else emit "$id" ACCEPT REFUSE FAIL \
    "$(printf '%s' "$err" | tail -1 | cut -c1-140)"; fi
}

# Five patterns below (p1, k1, k3, k4, k6) are the native emitter's wording.
# spinel-llvm wrote them against its retired Python generator, which said
# "Sub-register integers and buffers are refused in v1", "The profile declares
# these platform externs", "declares it :i32", "is an Integer ... declares it
# :f32" and "collides with a top-level method". The emitter is byte-identical
# in both repositories, so the refusals are the same ones; only k6's message
# lost its reason ("unsupported: 'gpio_set'" does not say it collides).

# -- A. the profile is validated before anything is generated ---------------
refuse p1_i8_param      ok.rb "$HERE/reject/p1_i8_param.yaml"      "parameter type .i8. is not one of i32/u32/i64/f32/f64"
refuse p2_no_returns    ok.rb "$HERE/reject/p2_no_returns.yaml"    "needs \`returns:\`"
refuse p3_unknown_key   ok.rb "$HERE/reject/p3_unknown_key.yaml"   "unknown key(s) lr"
refuse p4_bad_symbol    ok.rb "$HERE/reject/p4_bad_symbol.yaml"    "not a C identifier"
refuse p5_dup_name      ok.rb "$HERE/reject/p5_dup_name.yaml"      "declared twice"
refuse p6_none_no_symbol ok.rb "$HERE/reject/p6_none_no_symbol.yaml" "needs an explicit \`symbol:\` under platform.type none"
refuse p7_reserved      ok.rb "$HERE/reject/p7_reserved.yaml"      "reserved"
refuse p8_buf_param     ok.rb "$HERE/reject/p8_buf_param.yaml"     "parameter type 'i32_buf' is not one of"

# -- B. kernel-level misuse of a declared surface ---------------------------
refuse k1_undeclared    k1_undeclared.rb "$PROF" "call to .frobnicate., which is not a top-level method in this file and is not declared by the profile"
refuse k2_arity         k2_arity.rb      "$PROF" "call to platform extern 'gpio_set' with 1 argument(s)"
refuse k3_float_for_int k3_float_for_int.rb "$PROF" "argument 1 of platform extern .gpio_set. is a Float, but the profile declares :i32"
refuse k4_int_for_float k4_int_for_float.rb "$PROF" "argument 1 of platform extern .sense_scale. is a Integer, but the profile declares :f32"
refuse k5_buffer_to_extern k5_buffer_to_extern.rb "$PROF" "passing buffer \`b\` to platform extern 'checksum32'"
refuse k6_name_collision k6_name_collision.rb "$PROF" "unsupported: .gpio_set."
refuse k7_export_collision k7_export_collision.rb "$PROF" "cannot both define and import one symbol"

# -- C. controls ------------------------------------------------------------
accept c1_ok           c1_ok.rb           "$PROF"
accept c2_extern_free  c2_extern_free.rb  "$PROF"
accept c3_wrap_narrow  c3_wrap_narrow.rb  "$PROF"
# c2's stronger half: an extern-free kernel under the extern-bearing profile
# emits the SAME module (up to the header comment naming the profile file) as
# under the shipped profile -- the extern surface costs nothing unless used.
(cd "$W" && "$MLIRGEN" c2_extern_free.rb --freestanding \
    --profile "$FSDIR/profiles/cortex-m33-zephyr.yaml" -o c2_shipped.mlir) >/dev/null 2>&1
if diff <(grep -v '^//' "$W/c2_extern_free.mlir") \
        <(grep -v '^//' "$W/c2_shipped.mlir") >/dev/null 2>&1; then
  emit c4_extern_free_identical SAME SAME PASS \
    "extern-free kernel: e081 profile and shipped profile emit identical IR (comments aside)"
else
  emit c4_extern_free_identical SAME DIFFERENT FAIL "the extern surface leaked into unrelated IR"
fi
# c3's stronger half: the wrap entry really has no trap arm at the extern call.
if grep -q 'does not fit' "$W/c3_wrap_narrow.mlir"; then
  emit c5_wrap_no_traparm ABSENT PRESENT FAIL "a wrap entry grew a narrowing trap arm"
else
  emit c5_wrap_no_traparm ABSENT ABSENT PASS \
    "overflow: :wrap -- the extern argument truncates with no trap arm, as declared"
fi

cat "$T"
echo "reject.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
