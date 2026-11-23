#!/usr/bin/env bash
# E079 gates -- the four legs of one gradient, the runtime refusals, and the
# closed loop. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E079/run_gates.sh.
#
# Every leg runs objects this repository generated from e079_kern.rb: the host
# executable, kern.wasm under node, and the two Zephyr images under QEMU.
#
#   legs.tsv      each leg's stream reached `#done`, and is byte-identical to the
#                 host leg's: -enzyme-fast-math=0 is what makes one IR compute
#                 the same bits on targets with different fusion hardware (G5)
#   trap.tsv      the learning-rate guard: every leg refuses four rates without
#                 writing, and accepts the fifth
#   loop.tsv      device -> edge -> device: the weights the wasm32 leg computed,
#                 shipped as bits into a device image and applied there
#   fastmath.tsv  the control build with Enzyme's default fast-math, recorded
#                 beside the shipped one (a record, not a check)
#
# Not run: model.py's independent reimplementation (an oracle, and Python, which
# this repository does not admit; not imported). grad4.tsv and sgd.tsv were views
# of the same streams legs.tsv compares whole, and are not written.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_wasm
NO_DEVICE=${NO_DEVICE:-0}
[ "$NO_DEVICE" = 1 ] || need_zephyr
M33_BOARD=${M33_BOARD:-mps2/an521/cpu0}
QEMU_TIMEOUT=${QEMU_TIMEOUT:-600}
mkdir -p "$OUT/logs" "$RES"

# A Zephyr image does not exit, so the run is stopped on its terminator; QEMU is
# a grandchild of west, and a survivor's stale qemu.pid breaks the next run.
run_qemu() {   # $1 = build tag, $2 = log, $3 = terminator regex
  local tag=$1 log=$2 term=$3
  rm -f "$OUT/build_$tag/qemu.pid"
  ( "$WEST" build -d "$OUT/build_$tag" -t run > "$RES/$log" 2>&1 ) &
  local wpid=$!
  local i=0
  while [ $i -lt "$QEMU_TIMEOUT" ]; do
    grep -qE "$term" "$RES/$log" 2>/dev/null && break
    kill -0 "$wpid" 2>/dev/null || break
    sleep 1; i=$(( i + 1 ))
  done
  if [ -f "$OUT/build_$tag/qemu.pid" ]; then
    kill "$(cat "$OUT/build_$tag/qemu.pid")" 2>/dev/null || true
  fi
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  rm -f "$OUT/build_$tag/qemu.pid"
  return 0
}
# The device console carries Zephyr's banner too; the driver's stream is exactly
# the lines from `#kern` to `#done`.
extract() { tr -d '\r' < "$1" | awk '/^#kern /{on=1} on{print} /^#done$/{if(on) exit}'; }

echo "== native =="
"$OUT/native" > "$OUT/logs/native.txt" || true
echo "== wasm32 (node) =="
"$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" > "$OUT/logs/wasm32.txt" || true
LEGS="native wasm32"
if [ "$NO_DEVICE" != 1 ]; then
  echo "== QEMU Cortex-M33 =="
  run_qemu m33 qemu_m33.log '^#done'
  extract "$RES/qemu_m33.log" > "$OUT/logs/m33.txt"
  echo "== QEMU RV32 =="
  run_qemu riscv32 qemu_rv32.log '^#done'
  extract "$RES/qemu_rv32.log" > "$OUT/logs/rv32.txt"
  LEGS="$LEGS m33 rv32"
fi

# --- legs.tsv ----------------------------------------------------------------
REF="$OUT/logs/native.txt"
{
  printf 'leg\tlines\tdone\tdiffering_lines\tverdict\n'
  for l in $LEGS; do
    f="$OUT/logs/$l.txt"
    n=$(wc -l < "$f" | tr -d ' ')
    dn=$(grep -c '^#done$' "$f" || true)
    d=$(diff "$REF" "$f" | grep -c '^<' || true)
    v=PASS; { [ "$dn" = 1 ] && [ "$d" = 0 ] && [ "$n" -gt 1 ]; } || v=FAIL
    printf '%s\t%s\t%s\t%s\t%s\n' "$l" "$n" "$dn" "$d" "$v"
  done
} > "$RES/legs.tsv"
cat "$RES/legs.tsv"

# --- fastmath.tsv (a record) ---------------------------------------------------
"$OUT/native_fm" > "$OUT/logs/native_fm.txt" || true
"$NODE" "$HERE/run_node.mjs" "$OUT/fm/kern.wasm" > "$OUT/logs/wasm32_fm.txt" || true
{
  printf 'build\tdiffering_lines_native_vs_wasm32\tdiffering_G_components\n'
  for b in "shipped:" "control:_fm"; do
    name=${b%%:*}; sfx=${b#*:}
    d=$(diff "$OUT/logs/native$sfx.txt" "$OUT/logs/wasm32$sfx.txt" | grep -c '^<' || true)
    g=$(diff <(grep '^G ' "$OUT/logs/native$sfx.txt") <(grep '^G ' "$OUT/logs/wasm32$sfx.txt") \
         | grep -c '^<' || true)
    printf '%s\t%s\t%s\n' "$name" "$d" "$g"
  done
} > "$RES/fastmath.tsv"
cat "$RES/fastmath.tsv"

# --- trap.tsv: the learning-rate guard is IN THE KERNEL (e079_kern.rb s D) ------
{
  printf 'id\tleg\tlr\tret\twrote_nothing\tverdict\n'
  for l in $LEGS; do
    base=$(awk '$1=="S" && $2==40 {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
    for k in 0 1 2 3 4; do
      r=$(awk -v k=$k '$1=="A" && $2==k {print $3}' "$OUT/logs/$l.txt")
      w=$(awk -v k=$k '$1=="W" && $2==k {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
      case $k in
        0) lr="0.0" ; exp=-1 ;; 1) lr="-0.1" ; exp=-1 ;;
        2) lr="2.0" ; exp=-1 ;; 3) lr="NaN"  ; exp=-1 ;;
        *) lr="0.1" ; exp=5  ;;
      esac
      if [ "$k" = 4 ]; then
        wn=$([ "$w" != "$base" ] && echo "no (accepted)" || echo "UNEXPECTED")
        ok=$([ "$r" = "$exp" ] && [ "$w" != "$base" ] && echo PASS || echo FAIL)
      else
        wn=$([ "$w" = "$base" ] && echo yes || echo "NO -- it wrote")
        ok=$([ "$r" = "$exp" ] && [ "$w" = "$base" ] && echo PASS || echo FAIL)
      fi
      printf 'lr%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$l" "$lr" "$r" "$wn" "$ok"
    done
  done
} > "$RES/trap.tsv"
cat "$RES/trap.tsv"

# --- loop.tsv: device -> edge -> device --------------------------------------
if [ "$NO_DEVICE" != 1 ]; then
  echo "== the closed loop: ship the edge's weights into a device image =="
  EDGE_FINAL=$(grep '^#final ' "$OUT/logs/wasm32.txt" | cut -d' ' -f2-)
  {
    echo "/* generated by run_gates.sh -- the weights the edge (wasm32/node)"
    echo "   computed by 40 SGD steps on the gradient, as raw IEEE bit patterns. */"
    echo "static const unsigned long long e079_shipped[] = {"
    for h in $EDGE_FINAL; do echo "  0x${h}ULL,"; done
    echo "};"
    echo "#define E079_SHIPPED_BITS e079_shipped"
  } > "$OUT/gen/weights_shipped.h"
  cp "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$OUT/gen/spinel_freestanding.h"
  cp "$OUT/gen/spinel_grad.cortex-m33-zephyr.h" "$OUT/gen/spinel_grad.h"
  "$WEST" build -p always -b "$M33_BOARD" -d "$OUT/build_m33ship" "$HERE/zephyr" -- \
      -DSPINEL_OBJ="$OUT/gen/grad.cortex-m33-zephyr.o" \
      -DSPINEL_GEN_DIR="$OUT/gen" -DE079_DRV_DIR="$HERE/drv" \
      -DE079_SHIPPED=1 2>&1 | tail -2
  run_qemu m33ship qemu_m33_shipped.log '^#done'
  extract "$RES/qemu_m33_shipped.log" > "$OUT/logs/m33ship.txt"
  M=$OUT/logs/m33.txt; E=$OUT/logs/wasm32.txt; H=$OUT/logs/m33ship.txt
  {
    printf 'step\twhat\tverdict\tdetail\n'
    printf '1 device\tphase-0 verdicts on 64 samples\t%s\t%s\n' \
      "$(grep -q '^C0 ' "$M" && echo PASS || echo FAIL)" \
      "confusion (tn fp fn tp) = $(awk '$1=="C0"{print $2, $3, $4, $5}' "$M")"
    l0=$(awk '$1=="L" && $2==0{print $3}' "$E"); l40=$(awk '$1=="L" && $2==40{print $3}' "$E")
    printf '2 edge\t40 SGD steps on the Enzyme gradient (wasm32)\t%s\t%s\n' \
      "$([ -n "$l0" ] && [ -n "$l40" ] && echo PASS || echo FAIL)" "loss $l0 -> $l40"
    a=$(grep '^#final ' "$E" | cut -d' ' -f2-)
    b=$(grep '^#shipped ' "$H" | cut -d' ' -f2-)
    printf '3 ship\tthe edge weights, as bits, inside a device image\t%s\t%s\n' \
      "$([ -n "$a" ] && [ "$a" = "$b" ] && echo PASS || echo FAIL)" "$b"
    c=$(awk '$1=="X1"{print $2, $3}' "$H" | cksum)
    d=$(awk '$1=="V1"{print $2, $3}' "$M" | cksum)
    printf '4 apply\t64 verdicts from the shipped weights vs the device'"'"'s own\t%s\t%s\n' \
      "$([ "$c" = "$d" ] && echo PASS || echo FAIL)" \
      "confusion = $(awk '$1=="Y1"{print $2, $3, $4, $5}' "$H")"
    fp0=$(awk '$1=="C0"{print $3}' "$M"); fp1=$(awk '$1=="Y1"{print $3}' "$H")
    ac0=$(awk '$1=="C0"{print $2+$5}' "$M"); ac1=$(awk '$1=="Y1"{print $2+$5}' "$H")
    printf '5 improve\tfalse positives on the device\t%s\t%s -> %s (correct %s -> %s of 64)\n' \
      "$([ -n "$fp1" ] && [ "$fp1" -lt "${fp0:-0}" ] && echo PASS || echo FAIL)" \
      "$fp0" "$fp1" "$ac0" "$ac1"
  } > "$RES/loop.tsv"
  cat "$RES/loop.tsv"
fi

bad=$(cat "$RES/legs.tsv" "$RES/trap.tsv" "$RES"/loop.tsv 2>/dev/null | awk -F'\t' '$0 ~ /\tFAIL(\t|$)/' | wc -l | tr -d ' ')
echo "run_gates: $bad failing row(s)"
[ "$bad" = 0 ]
