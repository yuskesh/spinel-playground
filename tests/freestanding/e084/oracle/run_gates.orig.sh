#!/usr/bin/env bash
# E084 gates -- the four-way oracle for a KERNEL-HELD Newton-CG loop, the
# analytic-Hessian oracle for the freestanding hvp product, and the D-10
# runtime check against the NEW extern.
#
#   gates.tsv     four legs, one stream, one sha256
#   analytic.tsv  the closed-form gradient/Hessian oracle (native, links the
#                 objects, never Enzyme) -- E078 s5.2's identity at the
#                 freestanding boundary, at TWO active sets
#   hvpsym.tsv    symmetry u.Hv == v.Hu and GDOT ret == g.dir, computed from
#                 the PRINTED bits of every leg (the checker dots, the legs
#                 only print)
#   loop.tsv      loop-in-kernel == composition-of-chunks (F rows vs S 12
#                 rows, sum of K rcs vs B), per leg
#   trap.tsv      the refusals: bad iters/gtol2 (whole-run form, 4 legs) and
#                 the D-10 length check against the hvp extern (native /
#                 wasm / QEMU m33 panic)
#   surface.tsv   what the objects import and export (TWO extern symbols now)
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e084/oracle/run_gates.orig.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
OUT=${OUT:-$SCRATCH/e084/work}
LLVM_PREFIX=${LLVM_PREFIX:-/opt/homebrew/opt/llvm}
WEST=${WEST:-west}
NO_DEVICE=${NO_DEVICE:-0}
export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/sdk/zephyrproject/zephyr}"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"

mkdir -p "$OUT/logs"

# E067/E077/E079/E083's QEMU discipline: stop on the terminator, kill the pid.
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
      native) what="kern.o + grad.o (--grads-only, grad+hvp), arm64, C driver, Newton-CG in kernel" ;;
      wasm32) what="kern.wasm on node v24 (V8), JS driver, Newton-CG in kernel" ;;
      m33)    what="QEMU mps2/an521/cpu0 + Zephyr, soft float, Newton-CG in kernel" ;;
      rv32)   what="QEMU qemu_riscv32 + Zephyr, soft float, Newton-CG in kernel" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$l" "$what" "$n" "$h" "$d" "$v"
  done
} > "$HERE/gates.tsv"
cat "$HERE/gates.tsv"

# --- analytic.tsv: the closed-form oracle ---------------------------------
"$OUT/analytic_check" > "$HERE/analytic.tsv"
tail -1 "$HERE/analytic.tsv"

# --- hvpsym.tsv: symmetry and GDOT from the printed bits, per leg ---------
python3 - "$OUT/logs" "$LEGS" > "$HERE/hvpsym.tsv" <<'EOF'
# Reads the U/Z rows (H.u and H.v for the two fixed directions) and the
# V/Vr/G0 rows of every leg's stream and checks, from the BITS THE LEG
# PRINTED: (1) u.Hv == v.Hu (symmetry through the extern boundary), and
# (2) Vr j == G0 . e_j (the returned directional derivative is the
# gradient's component).  The legs never dot; this checker does.
import struct, sys, os
logs, legs = sys.argv[1], sys.argv[2].split()
U = [1.0, 0.5, -0.25, 2.0, -1.0]
V = [-0.5, 1.0, 0.75, -1.5, 0.25]
def f(h): return struct.unpack(">d", bytes.fromhex(h))[0]
print("leg\tcheck\tgot\twant\trelerr\tverdict")
bad = 0
for leg in legs:
    rows = {}
    for ln in open(os.path.join(logs, leg + ".txt")):
        p = ln.split()
        if p and p[0] in ("U", "Z", "V", "Vr", "G0"):
            rows[tuple(p[:-1])] = f(p[-1])
    hu = [rows[("U", str(i))] for i in range(5)]
    hv = [rows[("Z", str(i))] for i in range(5)]
    uhv = sum(U[i] * hv[i] for i in range(5))
    vhu = sum(V[i] * hu[i] for i in range(5))
    e = abs(uhv - vhu) / max(abs(vhu), 1e-12)
    ok = e <= 1e-12
    bad += not ok
    print("%s\tgsym\t%.17g\t%.17g\t%.3e\t%s" % (leg, uhv, vhu, e, "PASS" if ok else "FAIL"))
    for j in range(5):
        ret = rows[("Vr", str(j))]
        gj = rows[("G0", str(j))]
        e = abs(ret - gj) / max(abs(gj), 1e-12)
        ok = e <= 1e-12
        bad += not ok
        print("%s\tgdot.%d\t%.17g\t%.17g\t%.3e\t%s" % (leg, j, ret, gj, e, "PASS" if ok else "FAIL"))
print("#summary\t%d fail" % bad)
EOF
tail -1 "$HERE/hvpsym.tsv"

# --- loop.tsv: loop-in-kernel == composition of chunks ---------------------
{
  printf 'leg\tcheck\tverdict\tdetail\n'
  for l in $LEGS; do
    f="$OUT/logs/$l.txt"
    b=$(awk '$1=="B"{print $2}' "$f")
    ksum=$(awk '$1=="K"{s+=$3} END{print s}' "$f")
    ok=$([ "$b" = "$ksum" ] && [ -n "$b" ] && echo PASS || echo FAIL)
    printf '%s\tsteps_sum\t%s\tB=%s == sum of chunk rcs=%s\n' "$l" "$ok" "$b" "$ksum"
    s12=$(awk '$1=="S" && $2==12 {print $4}' "$f" | tr '\n' ',')
    fin=$(awk '$1=="F"{print $4}' "$f" | tr '\n' ',')
    ok=$([ -n "$s12" ] && [ "$s12" = "$fin" ] && echo PASS || echo FAIL)
    printf '%s\tone_call_equals_12_chunks\t%s\tF rows == S 12 rows, bitwise\n' "$l" "$ok"
    w4=$(awk '$1=="W" && $2==4 {print $4}' "$f" | tr '\n' ',')
    a4=$(awk '$1=="A" && $2==4 {print $3}' "$f")
    ok=$([ "$w4" = "$fin" ] && [ "$a4" = "$b" ] && echo PASS || echo FAIL)
    printf '%s\tcontrol_retraces\t%s\tA4 rc=%s == B, W4 rows == F rows\n' "$l" "$ok" "$a4"
  done
} > "$HERE/loop.tsv"
cat "$HERE/loop.tsv"

# --- trap.tsv: the refusals ------------------------------------------------
{
  printf 'id\tleg\tcase\tret\twrote_nothing\tverdict\n'
  # 1. iters/gtol2 refusals, whole-run form: a refused newton_calibrate
  #    writes NOTHING (bitwise, against the converged weights it was handed).
  for l in $LEGS; do
    base=$(awk '$1=="S" && $2==12 {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
    fin=$(awk '$1=="F"{print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
    for k in 0 1 2 3 4; do
      r=$(awk -v k=$k '$1=="A" && $2==k {print $3}' "$OUT/logs/$l.txt")
      w=$(awk -v k=$k '$1=="W" && $2==k {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
      case $k in
        0) c="iters=0"    ; exp=-1 ;; 1) c="iters=-3"   ; exp=-1 ;;
        2) c="gtol2=-1.0" ; exp=-1 ;; 3) c="gtol2=NaN"  ; exp=-1 ;;
        *) c="control"    ; exp=7  ;;
      esac
      if [ "$k" = 4 ]; then
        wn=$([ "$w" = "$fin" ] && echo "wrote (== F rows)" || echo UNEXPECTED)
        ok=$([ "$r" = "$exp" ] && [ "$w" = "$fin" ] && echo PASS || echo FAIL)
      else
        wn=$([ "$w" = "$base" ] && echo yes || echo "NO -- it wrote")
        ok=$([ "$r" = "$exp" ] && [ "$w" = "$base" ] && echo PASS || echo FAIL)
      fi
      printf 'nc%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$l" "$c" "$r" "$wn" "$ok"
    done
  done
  # 2. the D-10 length check against the HVP extern, native: trap 4, exit 3.
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
  # 3. the same check on the edge.
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
  #    after it.
  if [ "$NO_DEVICE" != 1 ]; then
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
  # the kernel object imports the two adjoint products + the trap hook
  for t in arm64-host cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    n=$(awk -F'\t' '$1=="ALLOW" && $4=="platform extern declared by the profile"' \
        "$HERE/undef.kern.$t.tsv" | wc -l | tr -d ' ')
    d=$(awk -F'\t' '$1=="DENY"' "$HERE/undef.kern.$t.tsv" | wc -l | tr -d ' ')
    printf 'kern_undef.%s\textern_allows=%s deny=%s\t%s\n' "$t" "$n" "$d" \
      "$([ "$d" = 0 ] && echo PASS || echo FAIL)"
  done
  # the adjoint object exports exactly the two products
  ex=$("$LLVM_PREFIX/bin/llvm-nm" --defined-only --extern-only \
       "$OUT/gen/grad.cortex-m33-zephyr.o" | awk 'NF==3{print $3}' | sort | tr '\n' ',')
  printf 'grad_exports\t%s\t%s\n' "$ex" \
    "$([ "$ex" = "spinel_grad_sq_hinge_loss,spinel_hvp_sq_hinge_loss," ] && echo PASS || echo FAIL)"
  # the linked wasm module imports ONE function
  imp=$("$LLVM_PREFIX/bin/obj2yaml" "$OUT/gen/kern.wasm" | \
        awk '/Field:/{print $2}' | tr '\n' ',')
  printf 'wasm_imports\t%s\t%s\n' "$imp" \
    "$([ "$imp" = "spinel_trap,memory," ] || [ "$imp" = "spinel_trap," ] && echo PASS || echo FAIL)"
  # the kernel object ALONE still imports both products (the externs are real)
  u=$("$LLVM_PREFIX/bin/llvm-nm" --undefined-only "$OUT/gen/kern.wasm32-worker.o" \
      | awk '{print $2}' | sort | tr '\n' ',')
  printf 'kern_wasm_undef\t%s\t%s\n' "$u" \
    "$([ "$u" = "spinel_grad_sq_hinge_loss,spinel_hvp_sq_hinge_loss,spinel_trap," ] && echo PASS || echo FAIL)"
} > "$HERE/surface.tsv"
cat "$HERE/surface.tsv"

echo "== summary =="
awk -F'\t' 'NR>1 && $6!="IDENTICAL"' "$HERE/gates.tsv" | wc -l | \
  xargs -I{} echo "gates.tsv: {} diverging leg(s)"
grep -c 'FAIL' "$HERE/analytic.tsv" | xargs -I{} echo "analytic.tsv: {} failing row(s)"
grep -c 'FAIL' "$HERE/hvpsym.tsv" | xargs -I{} echo "hvpsym.tsv: {} failing row(s)"
awk -F'\t' 'NR>1 && $3!="PASS" && $1!~"^#"' "$HERE/loop.tsv" | wc -l | \
  xargs -I{} echo "loop.tsv: {} failing check(s)"
awk -F'\t' 'NR>1 && $NF!="PASS"' "$HERE/trap.tsv" | wc -l | \
  xargs -I{} echo "trap.tsv: {} failing refusal(s)"
awk -F'\t' 'NR>1 && $NF!="PASS"' "$HERE/surface.tsv" | wc -l | \
  xargs -I{} echo "surface.tsv: {} failing surface check(s)"
