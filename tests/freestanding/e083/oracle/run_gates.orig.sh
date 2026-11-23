#!/usr/bin/env bash
# E083 gates -- the four-way oracle for a KERNEL-HELD optimizer loop, and the
# bit-identity of its trajectory against E079's stored artefacts.
#
#   gates.tsv    four legs, one stream, one sha256
#   e079.tsv     row-by-row against E079's STORED results: 41 loss rows and
#                200 weight rows from results/E079/sgd.tsv, plus the shipped
#                weights of weights_shipped.h -- the loop moved INTO the
#                kernel and not one bit of the trajectory moved with it
#   loop.tsv     loop-in-kernel == composition-of-chunks (F rows vs S 40 rows),
#                per leg
#   trap.tsv     the refusals: bad learning rates (whole-loop form, 4 legs)
#                and the D-10 length check (native / wasm / QEMU m33 panic)
#   surface.tsv  what the objects import and the module imports (the extern
#                surface, counted, on every leg)
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e083/oracle/run_gates.orig.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
OUT=${OUT:-$SCRATCH/e083/work}
LLVM_PREFIX=${LLVM_PREFIX:-/opt/homebrew/opt/llvm}
WEST=${WEST:-west}
NO_DEVICE=${NO_DEVICE:-0}
export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/sdk/zephyrproject/zephyr}"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"

mkdir -p "$OUT/logs"

# E067/E077/E079's QEMU discipline: stop on the terminator, kill the pid file.
run_qemu() {   # $1 = build tag, $2 = log, $3 = terminator regex
  local tag=$1 log=$2 term=$3
  rm -f "$OUT/build_$tag/qemu.pid"
  ( "$WEST" build -d "$OUT/build_$tag" -t run > "$HERE/$log" 2>&1 ) &
  local wpid=$!
  local i=0
  while [ $i -lt 600 ]; do
    grep -qE "$term" "$HERE/$log" 2>/dev/null && break
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
extract() { tr -d '\r' < "$1" | awk '/^#kern /{on=1} on{print} /^#done$/{if(on) exit}'; }

echo "== 1. native (arm64) =="
"$OUT/native" > "$OUT/logs/native.txt"

echo "== 2. wasm32 (node) -- THE EDGE =="
node "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" > "$OUT/logs/wasm32.txt"

if [ "$NO_DEVICE" != 1 ]; then
  echo "== 3. QEMU Cortex-M33 -- THE DEVICE =="
  run_qemu m33 qemu_m33.log '^#done'
  extract "$HERE/qemu_m33.log" > "$OUT/logs/m33.txt"
  echo "== 4. QEMU RV32 =="
  run_qemu riscv32 qemu_rv32.log '^#done'
  extract "$HERE/qemu_rv32.log" > "$OUT/logs/rv32.txt"
  LEGS="native wasm32 m33 rv32"
else
  LEGS="native wasm32"
fi

# --- gates.tsv: the whole stream, four legs -------------------------------
REF="$OUT/logs/native.txt"
{
  printf 'leg\twhat\tlines\tsha256_16\tdiffering_lines\tverdict\n'
  for l in $LEGS; do
    f="$OUT/logs/$l.txt"
    n=$(wc -l < "$f" | tr -d ' ')
    h=$(shasum -a 256 "$f" | cut -c1-16)
    d=$(diff "$REF" "$f" | grep -c '^<' || true)
    v=IDENTICAL; [ "$d" = 0 ] || v=DIVERGE
    case "$l" in
      native) what="kern.o + grad.o (--grads-only), arm64, C driver, loop in kernel" ;;
      wasm32) what="kern.wasm on node v24 (V8), JS driver, loop in kernel" ;;
      m33)    what="QEMU mps2/an521/cpu0 + Zephyr, soft float, loop in kernel" ;;
      rv32)   what="QEMU qemu_riscv32 + Zephyr, soft float, loop in kernel" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$l" "$what" "$n" "$h" "$d" "$v"
  done
} > "$HERE/gates.tsv"
cat "$HERE/gates.tsv"

# --- e079.tsv: the trajectory against E079's STORED stream -----------------
# E079's sgd.tsv holds the loss bits and the five weight bit patterns for all
# forty steps, written by drivers that HELD the loop.  Every row here compares
# one of those stored numbers with the same number from the kernel-held loop.
python3 - "$OUT/logs/native.txt" "$HERE/../E079/sgd.tsv" \
    "$HERE/../E079/weights_shipped.h" > "$HERE/e079.tsv" <<'EOF'
import re, sys
log, sgd, shipped = sys.argv[1], sys.argv[2], sys.argv[3]
L, S, final = {}, {}, None
for ln in open(log):
    p = ln.split()
    if not p: continue
    if p[0] == "L": L[int(p[1])] = p[2]
    elif p[0] == "S": S.setdefault(int(p[1]), {})[int(p[2])] = p[3]
    elif p[0] == "#final": final = p[1:]
rows = []
import csv
for row in csv.DictReader(open(sgd), delimiter="\t"):
    t = int(row["step"])
    rows.append(("loss.%d" % t, row["loss_bits"], L.get(t)))
    if t >= 1:
        for j in range(5):
            rows.append(("w%d.%d" % (j, t), row["w%d" % j], S.get(t, {}).get(j)))
ship = re.findall(r"0x([0-9a-f]{16})ULL", open(shipped).read())
for j, h in enumerate(ship):
    rows.append(("shipped.w%d" % j, h, final[j] if final else None))
bad = 0
print("row\te079_stored\te083_kernel_loop\tverdict")
for k, a, b in rows:
    v = "SAME" if a == b and a else "DIFFER"
    if v != "SAME": bad += 1
    print("%s\t%s\t%s\t%s" % (k, a, b, v))
print("#summary\t%d rows\t%d differ\t%s" % (len(rows), bad,
      "BIT-IDENTICAL" if bad == 0 else "DIVERGE"))
EOF
tail -1 "$HERE/e079.tsv"

# --- loop.tsv: loop-in-kernel == composition of chunks ---------------------
{
  printf 'leg\tcheck\tverdict\tdetail\n'
  for l in $LEGS; do
    f="$OUT/logs/$l.txt"
    b=$(awk '$1=="B"{print $2}' "$f")
    ok=$([ "$b" = 40 ] && echo PASS || echo FAIL)
    printf '%s\twhole_loop_rc\t%s\trc=%s (one call, steps=40)\n' "$l" "$ok" "$b"
    s40=$(awk '$1=="S" && $2==40 {print $4}' "$f" | tr '\n' ',')
    fin=$(awk '$1=="F"{print $4}' "$f" | tr '\n' ',')
    ok=$([ -n "$s40" ] && [ "$s40" = "$fin" ] && echo PASS || echo FAIL)
    printf '%s\tone_call_equals_40_chunks\t%s\tF rows == S 40 rows, bitwise\n' "$l" "$ok"
    k=$(awk '$1=="K" && $3!=1' "$f" | wc -l | tr -d ' ')
    ok=$([ "$k" = 0 ] && echo PASS || echo FAIL)
    printf '%s\tchunk_rcs\t%s\tevery steps=1 call returned 1\n' "$l" "$ok"
  done
} > "$HERE/loop.tsv"
cat "$HERE/loop.tsv"

# --- trap.tsv: the refusals ------------------------------------------------
{
  printf 'id\tleg\tcase\tret\twrote_nothing\tverdict\n'
  # 1. learning rates, whole-loop form: a refused calibrate(steps=40) writes
  #    NOTHING (compared bitwise against the weights it was handed).
  for l in $LEGS; do
    base=$(awk '$1=="S" && $2==40 {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
    for k in 0 1 2 3 4; do
      r=$(awk -v k=$k '$1=="A" && $2==k {print $3}' "$OUT/logs/$l.txt")
      w=$(awk -v k=$k '$1=="W" && $2==k {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
      case $k in
        0) lr="lr=0.0" ; exp=-1 ;; 1) lr="lr=-0.1" ; exp=-1 ;;
        2) lr="lr=2.0" ; exp=-1 ;; 3) lr="lr=NaN"  ; exp=-1 ;;
        *) lr="lr=0.1" ; exp=40 ;;
      esac
      if [ "$k" = 4 ]; then
        wn=$([ "$w" != "$base" ] && echo "no (accepted, 40 more steps)" || echo UNEXPECTED)
        ok=$([ "$r" = "$exp" ] && [ "$w" != "$base" ] && echo PASS || echo FAIL)
      else
        wn=$([ "$w" = "$base" ] && echo yes || echo "NO -- it wrote")
        ok=$([ "$r" = "$exp" ] && [ "$w" = "$base" ] && echo PASS || echo FAIL)
      fi
      printf 'lr%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$l" "$lr" "$r" "$wn" "$ok"
    done
  done
  # 2. the D-10 length check, native: trap code 4, exit 3, UNREACHED absent.
  for probe in trap1:1 trapneg:-6; do
    tag=${probe%%:*}; extra=${probe##*:}
    "$OUT/native_$tag" > "$OUT/logs/nat_$tag.out" 2> "$OUT/logs/nat_$tag.err"
    rc=$?
    line=$(grep -c 'TRAP.code=4' "$OUT/logs/nat_$tag.err" || true)
    unr=$(grep -c UNREACHED "$OUT/logs/nat_$tag.out" || true)
    ok=$([ "$rc" = 3 ] && [ "$line" = 1 ] && [ "$unr" = 0 ] && echo PASS || echo FAIL)
    printf 'len_%s\tnative\textra=%s\texit=%s\ttrap4=%s unreached=%s\t%s\n' \
      "$tag" "$extra" "$rc" "$line" "$unr" "$ok"
  done
  # 3. the same check on the edge: env.spinel_trap fires, exit 3.
  for extra in 1 -6; do
    node "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" --trap "$extra" \
        > "$OUT/logs/wasm_trap$extra.out" 2>&1
    rc=$?
    line=$(grep -c 'TRAP.code=4' "$OUT/logs/wasm_trap$extra.out" || true)
    unr=$(grep -c UNREACHED "$OUT/logs/wasm_trap$extra.out" || true)
    ok=$([ "$rc" = 3 ] && [ "$line" = 1 ] && [ "$unr" = 0 ] && echo PASS || echo FAIL)
    printf 'len_trap%s\twasm32\textra=%s\texit=%s\ttrap4=%s unreached=%s\t%s\n' \
      "$extra" "$extra" "$rc" "$line" "$unr" "$ok"
  done
  # 4. the device: the m33 panic build reaches trap 4 and executes nothing
  #    after it (Zephyr reports the fatal error; UNREACHED never prints).
  if [ "$NO_DEVICE" != 1 ]; then
    # k_panic() on this board surfaces as the fault handler's register dump
    # ("Faulting instruction address"); the ZEPHYR FATAL ERROR banner is not
    # always flushed before the runner stops QEMU, so the dump is the witness.
    run_qemu m33trap qemu_m33_trap.log 'Faulting instruction|ZEPHYR FATAL ERROR|Halting system|UNREACHED'
    line=$(grep -c 'TRAP.code=4' "$HERE/qemu_m33_trap.log" || true)
    unr=$(grep -c UNREACHED "$HERE/qemu_m33_trap.log" || true)
    halt=$(grep -cE 'ZEPHYR FATAL ERROR|Halting system|Faulting instruction address' "$HERE/qemu_m33_trap.log" || true)
    ok=$([ "$line" -ge 1 ] && [ "$unr" = 0 ] && [ "$halt" -ge 1 ] && echo PASS || echo FAIL)
    printf 'len_trap1\tm33\textra=1\tpanic\ttrap4=%s halt=%s unreached=%s\t%s\n' \
      "$line" "$halt" "$unr" "$ok"
  fi
} > "$HERE/trap.tsv"
cat "$HERE/trap.tsv"

# --- surface.tsv: the extern surface, counted ------------------------------
{
  printf 'check\tvalue\tverdict\n'
  # the kernel object imports the adjoint + the trap hook, nothing else
  for t in arm64-host cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    n=$(awk -F'\t' '$1=="ALLOW" && $4=="platform extern declared by the profile"' \
        "$HERE/undef.kern.$t.tsv" | wc -l | tr -d ' ')
    d=$(awk -F'\t' '$1=="DENY"' "$HERE/undef.kern.$t.tsv" | wc -l | tr -d ' ')
    printf 'kern_undef.%s\textern_allows=%s deny=%s\t%s\n' "$t" "$n" "$d" \
      "$([ "$d" = 0 ] && echo PASS || echo FAIL)"
  done
  # the adjoint object exports exactly one symbol
  ex=$("$LLVM_PREFIX/bin/llvm-nm" --defined-only --extern-only \
       "$OUT/gen/grad.cortex-m33-zephyr.o" | awk 'NF==3{print $3}' | tr '\n' ',')
  printf 'grad_exports\t%s\t%s\n' "$ex" \
    "$([ "$ex" = "spinel_grad_sq_hinge_loss," ] && echo PASS || echo FAIL)"
  # the linked wasm module imports ONE function
  imp=$("$LLVM_PREFIX/bin/obj2yaml" "$OUT/gen/kern.wasm" | \
        awk '/Field:/{print $2}' | tr '\n' ',')
  printf 'wasm_imports\t%s\t%s\n' "$imp" \
    "$([ "$imp" = "spinel_trap,memory," ] || [ "$imp" = "spinel_trap," ] && echo PASS || echo FAIL)"
  # the kernel object ALONE still imports the adjoint (the extern is real)
  u=$("$LLVM_PREFIX/bin/llvm-nm" --undefined-only "$OUT/gen/kern.wasm32-worker.o" \
      | awk '{print $2}' | sort | tr '\n' ',')
  printf 'kern_wasm_undef\t%s\t%s\n' "$u" \
    "$([ "$u" = "spinel_grad_sq_hinge_loss,spinel_trap," ] && echo PASS || echo FAIL)"
} > "$HERE/surface.tsv"
cat "$HERE/surface.tsv"

echo "== summary =="
awk -F'\t' 'NR>1 && $6!="IDENTICAL"' "$HERE/gates.tsv" | wc -l | \
  xargs -I{} echo "gates.tsv: {} diverging leg(s)"
grep -c 'DIFFER' "$HERE/e079.tsv" | xargs -I{} echo "e079.tsv: {} differing row(s)"
awk -F'\t' 'NR>1 && $3!="PASS" && $1!~"^#"' "$HERE/loop.tsv" | wc -l | \
  xargs -I{} echo "loop.tsv: {} failing check(s)"
awk -F'\t' 'NR>1 && $NF!="PASS"' "$HERE/trap.tsv" | wc -l | \
  xargs -I{} echo "trap.tsv: {} failing refusal(s)"
awk -F'\t' 'NR>1 && $NF!="PASS"' "$HERE/surface.tsv" | wc -l | \
  xargs -I{} echo "surface.tsv: {} failing surface check(s)"
