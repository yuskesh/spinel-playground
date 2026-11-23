#!/usr/bin/env bash
# E084: the rejection table -- what the Newton kernel COULD NOT be written
# with (the subset refusals that shaped e084_kern.rb, kept as executable
# records), and the gradfs hvp-gate refusals (draft G9-fs).  E038/E040's
# discipline: a table with only rejections can be passed by a tool that
# rejects everything, so the accepted pairs (n5, hc1, c1) are rows too.
#
#   bash run_reject.sh   -> reject.tsv
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e084/oracle/run_reject.orig.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../../workdir.sh"
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
W=$SCRATCH/e084/reject
MLIRGEN=$REPO/tools/mlir/spinel-mlirgen
GRADFS=$REPO/tools/grad/spinel-gradfs
FSDIR=$REPO/tools/freestanding
PROF=$HERE/cortex-m33-zephyr-e084.yaml

fs_fresh_workdir "$W"; mkdir -p "$W/spinel" "$W/out"
cp "$FSDIR/spinel/freestanding.rb" "$W/spinel/"
cp "$REPO/tools/grad/spinel/grad_freestanding.rb" "$W/spinel/"
cp "$HERE/reject/"*.rb "$W/"
cp "$HERE/e084_kern.rb" "$W/"

pass=0; fail=0
T=$HERE/reject.tsv
printf 'id\ttool\texpect\tgot\tverdict\tpattern_or_note\n' > "$T"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$T"
         if [ "$5" = PASS ]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

refuse_mlir() {  # id, kernel, stderr-pattern
  local id=$1 kern=$2 pat=$3 err rc
  err=$( (cd "$W" && "$MLIRGEN" "$kern" --freestanding --profile "$PROF" \
          -o "$W/$id.o") 2>&1 ); rc=$?
  if [ $rc != 0 ] && printf '%s' "$err" | grep -q "$pat"; then
    emit "$id" mlirgen REFUSE REFUSE PASS "$pat"
  elif [ $rc != 0 ]; then
    emit "$id" mlirgen REFUSE "REFUSE(wrong reason)" FAIL \
      "$(printf '%s' "$err" | tail -1 | cut -c1-140)"
  else
    emit "$id" mlirgen REFUSE ACCEPT FAIL "compiled"
  fi
}
accept_mlir() {  # id, kernel
  local id=$1 kern=$2 err rc
  err=$( (cd "$W" && "$MLIRGEN" "$kern" --freestanding --profile "$PROF" \
          -o "$W/$id.o") 2>&1 ); rc=$?
  if [ $rc = 0 ]; then emit "$id" mlirgen ACCEPT ACCEPT PASS "control"
  else emit "$id" mlirgen ACCEPT REFUSE FAIL \
    "$(printf '%s' "$err" | tail -1 | cut -c1-140)"; fi
}
refuse_gradfs() {  # id, kernel, stderr-pattern
  local id=$1 kern=$2 pat=$3 err rc
  err=$( (cd "$W" && "$GRADFS" "$kern" --profile "$PROF" -o out --tag "$id") 2>&1 ); rc=$?
  if [ $rc != 0 ] && printf '%s' "$err" | grep -q "$pat"; then
    emit "$id" gradfs REFUSE REFUSE PASS "$pat"
  elif [ $rc != 0 ]; then
    emit "$id" gradfs REFUSE "REFUSE(wrong reason)" FAIL \
      "$(printf '%s' "$err" | tail -1 | cut -c1-140)"
  else
    emit "$id" gradfs REFUSE ACCEPT FAIL "compiled"
  fi
}

# -- A. the subset refusals that shaped the Newton kernel -------------------
refuse_mlir n1_sqrt      n1_sqrt.rb      "ConstantReadNode is not in the freestanding subset"
refuse_mlir n2_array_new n2_array_new.rb "indexes a heap object"
refuse_mlir n3_block     n3_block.rb     "takes a block"
refuse_mlir n4_loop_mul  n4_loop_mul.rb  "assigns a Float to \`x\`, which whole-program inference typed as an Integer"
accept_mlir n5_loop_div  n5_loop_div.rb

# -- B. the gradfs hvp gates (draft G9-fs) ----------------------------------
refuse_gradfs h1_hvp_multi_wrt h1_hvp_multi_wrt.rb "hvp: true with 2 wrt: parameters"
refuse_gradfs h2_hvp_nonbool   h2_hvp_nonbool.rb   "hvp: takes true or false"
refuse_gradfs h3_jvp_unknown   h3_jvp_unknown.rb   "unknown keyword \`jvp:\`"

# hc1 (control): hvp: false == the pre-E084 declaration; ONE export.
if (cd "$W" && "$GRADFS" hc1_hvp_false.rb --profile "$PROF" --grads-only \
      -o out --tag hc1) >/dev/null 2>&1; then
  ex=$(/opt/homebrew/opt/llvm/bin/llvm-nm --defined-only --extern-only \
       "$W/out/grad.hc1.o" | awk 'NF==3{print $3}' | sort | tr '\n' ',')
  if [ "$ex" = "spinel_grad_one," ]; then
    emit hc1_hvp_false gradfs ACCEPT ACCEPT PASS "exports=$ex (no hvp symbol)"
  else
    emit hc1_hvp_false gradfs ACCEPT ACCEPT FAIL "unexpected exports: $ex"
  fi
else
  emit hc1_hvp_false gradfs ACCEPT REFUSE FAIL "hvp: false was refused"
fi

# c1 (control): the real E084 kernel, both tools, end to end.
accept_mlir c1_kernel e084_kern.rb
if (cd "$W" && "$GRADFS" e084_kern.rb --profile "$PROF" --grads-only \
      -o out --tag c1) >/dev/null 2>&1; then
  emit c1_gradfs gradfs ACCEPT ACCEPT PASS "control (grad + hvp)"
else
  emit c1_gradfs gradfs ACCEPT REFUSE FAIL "the shipping kernel was refused"
fi

cat "$T"
echo "reject.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
