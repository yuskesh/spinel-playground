#!/usr/bin/env bash
# E084: the rejection table -- what the Newton kernel could not be written with
# (the subset refusals that shaped e084_kern.rb) and spinel-fs-grad's hvp gates
# (draft G9-fs), with the accepted pairs (n3 since decision 0041, n5, hc1,
# c1) as rows too. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E084/run_reject.sh.
#
# Local changes: spinel-fs-emit and spinel-fs-grad where spinel-llvm called
# spinel-mlirgen and its retired spinel-gradfs; every pattern is unchanged,
# except n3, which decision 0041 stage 1 turned from a refusal into an
# accepted row.
#
#   bash run_reject.sh   -> $RES/reject.tsv
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_enzyme
mkdir -p "$RES"
W=$OUT/reject
PROF=$HERE/cortex-m33-zephyr-e084.yaml
fs_fresh_workdir "$W"; mkdir -p "$W/spinel" "$W/out"
cp "$FSDIR/spinel/freestanding.rb" "$REPO/tools/grad/spinel/grad_freestanding.rb" "$W/spinel/"
cp "$HERE/reject/"*.rb "$HERE/e084_kern.rb" "$W/"

pass=0; fail=0
T=$RES/reject.tsv
printf 'id\ttool\texpect\tgot\tverdict\tpattern_or_note\n' > "$T"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$T"
         if [ "$5" = PASS ]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
refuse() {  # tool, id, kernel, stderr-pattern
  local tool=$1 id=$2 kern=$3 pat=$4 err rc
  if [ "$tool" = fs-emit ]; then
    err=$( (cd "$W" && "$MLIRGEN" "$kern" --freestanding --profile "$PROF" -o "$W/$id.o") 2>&1 ); rc=$?
  else
    err=$( (cd "$W" && "$FSGRAD" "$kern" --profile "$PROF" -o out --tag "$id" --enzyme "$ENZYME") 2>&1 ); rc=$?
  fi
  if [ $rc != 0 ] && printf '%s' "$err" | grep -q "$pat"; then
    emit "$id" "$tool" REFUSE REFUSE PASS "$pat"
  elif [ $rc != 0 ]; then
    emit "$id" "$tool" REFUSE "REFUSE(wrong reason)" FAIL "$(printf '%s' "$err" | tail -1 | cut -c1-140)"
  else
    emit "$id" "$tool" REFUSE ACCEPT FAIL "compiled"
  fi
}
accept_emit() {  # id, kernel
  local id=$1 kern=$2 err rc
  err=$( (cd "$W" && "$MLIRGEN" "$kern" --freestanding --profile "$PROF" -o "$W/$id.o") 2>&1 ); rc=$?
  if [ $rc = 0 ]; then emit "$id" fs-emit ACCEPT ACCEPT PASS "control"
  else emit "$id" fs-emit ACCEPT REFUSE FAIL "$(printf '%s' "$err" | tail -1 | cut -c1-140)"; fi
}

# -- A. the subset refusals that shaped the Newton kernel -------------------
refuse fs-emit n1_sqrt      n1_sqrt.rb      "ConstantReadNode is not in the freestanding subset"
refuse fs-emit n2_array_new n2_array_new.rb "indexes a heap object"
accept_emit n3_block n3_block.rb  # decision 0041 stage 1: was refused, "takes a block"
accept_emit n4_loop_mul n4_loop_mul.rb  # pin baddd25a9 (upstream bd53f5938): was refused, "assigns a Float to `x`, which whole-program inference typed as an Integer"
accept_emit n5_loop_div n5_loop_div.rb
# -- B. the hvp gates (draft G9-fs) ------------------------------------------
refuse fs-grad h1_hvp_multi_wrt h1_hvp_multi_wrt.rb "hvp: true with 2 wrt: parameters"
refuse fs-grad h2_hvp_nonbool   h2_hvp_nonbool.rb   "hvp: takes true or false"
refuse fs-grad h3_jvp_unknown   h3_jvp_unknown.rb   "unknown keyword \`jvp:\`"
# hc1 (control): hvp: false is the pre-E084 declaration; one export.
if (cd "$W" && "$FSGRAD" hc1_hvp_false.rb --profile "$PROF" --grads-only \
      -o out --tag hc1 --enzyme "$ENZYME") >/dev/null 2>&1; then
  ex=$("$NM" --defined-only --extern-only "$W/out/grad.hc1.o" | awk 'NF==3{print $3}' | sort | tr '\n' ',')
  if [ "$ex" = "spinel_grad_one," ]; then
    emit hc1_hvp_false fs-grad ACCEPT ACCEPT PASS "exports=$ex (no hvp symbol)"
  else
    emit hc1_hvp_false fs-grad ACCEPT ACCEPT FAIL "unexpected exports: $ex"
  fi
else
  emit hc1_hvp_false fs-grad ACCEPT REFUSE FAIL "hvp: false was refused"
fi
# c1 (control): the real E084 kernel, both tools, end to end.
accept_emit c1_kernel e084_kern.rb
if (cd "$W" && "$FSGRAD" e084_kern.rb --profile "$PROF" --grads-only \
      -o out --tag c1 --enzyme "$ENZYME") >/dev/null 2>&1; then
  emit c1_fsgrad fs-grad ACCEPT ACCEPT PASS "control (grad + hvp)"
else
  emit c1_fsgrad fs-grad ACCEPT REFUSE FAIL "the shipping kernel was refused"
fi
cat "$T"
echo "reject.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ]
