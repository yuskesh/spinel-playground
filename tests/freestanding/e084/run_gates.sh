#!/usr/bin/env bash
# E084 gates -- a kernel-held Newton-CG loop on four legs. Ported from
# spinel-llvm 463d49dd docs/experiments/results/E084/run_gates.sh (the original
# is in oracle/run_gates.orig.sh).
#
#   legs.tsv     each leg's stream reached `#done` and is byte-identical to the
#                host leg's
#   hvpsym.tsv   from the bits each leg printed: u.Hv == v.Hu (the Hessian's
#                symmetry through the extern boundary), and the directional
#                derivative the hvp returns equals the gradient's component.
#                spinel-llvm computed it in inline Python; here in Ruby.
#   loop.tsv     per leg: B == the sum of the chunk rcs, one call equals twelve
#                chunks bitwise, and the accepted control retraces the run
#   trap.tsv     bad iters/gtol2 refused without writing (four legs), and the
#                D-10 length check against the hvp extern (native, wasm32, QEMU
#                m33 panic)
#   surface.tsv  what the objects import and export (two extern symbols)
#
# Not run: analytic.tsv, the closed-form gradient and Hessian written by hand
# (analytic_check.c, an oracle, in oracle/).
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_wasm
NO_DEVICE=${NO_DEVICE:-0}
[ "$NO_DEVICE" = 1 ] || need_zephyr
QEMU_TIMEOUT=${QEMU_TIMEOUT:-600}
mkdir -p "$OUT/logs" "$RES"

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
extract() { tr -d '\r' < "$1" | awk '/^#kern /{on=1} on{print} /^#done$/{if(on) exit}'; }

echo "== native =="
"$OUT/native" > "$OUT/logs/native.txt"
echo "== wasm32 (node) =="
"$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" > "$OUT/logs/wasm32.txt"
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

# --- hvpsym.tsv: symmetry and GDOT from the printed bits, per leg ---------
ruby - "$OUT/logs" "$LEGS" > "$RES/hvpsym.tsv" <<'EOF'
U = [1.0, 0.5, -0.25, 2.0, -1.0]
V = [-0.5, 1.0, 0.75, -1.5, 0.25]
logs, legs = ARGV[0], ARGV[1].split
f = ->(h) { [h].pack("H*").unpack1("G") }
puts "leg\tcheck\tgot\twant\trelerr\tverdict"
legs.each do |leg|
  rows = {}
  File.foreach(File.join(logs, "#{leg}.txt")) do |ln|
    p = ln.split
    rows[p[0...-1]] = f.(p[-1]) if !p.empty? && %w[U Z V Vr G0].include?(p[0])
  end
  hu = (0...5).map { |i| rows.fetch(["U", i.to_s]) }
  hv = (0...5).map { |i| rows.fetch(["Z", i.to_s]) }
  uhv = (0...5).sum { |i| U[i] * hv[i] }
  vhu = (0...5).sum { |i| V[i] * hu[i] }
  e = (uhv - vhu).abs / [vhu.abs, 1e-12].max
  puts [leg, "gsym", format("%.17g", uhv), format("%.17g", vhu), format("%.3e", e), e <= 1e-12 ? "PASS" : "FAIL"].join("\t")
  5.times do |j|
    ret = rows.fetch(["Vr", j.to_s]); gj = rows.fetch(["G0", j.to_s])
    e = (ret - gj).abs / [gj.abs, 1e-12].max
    puts [leg, "gdot.#{j}", format("%.17g", ret), format("%.17g", gj), format("%.3e", e), e <= 1e-12 ? "PASS" : "FAIL"].join("\t")
  end
end
EOF
[ -s "$RES/hvpsym.tsv" ] || printf 'leg\tcheck\tgot\twant\trelerr\tverdict\nall\tread\t-\t-\t-\tFAIL\n' > "$RES/hvpsym.tsv"
cat "$RES/hvpsym.tsv"

# --- loop.tsv: loop-in-kernel == composition of chunks ---------------------
{
  printf 'leg\tcheck\tverdict\tdetail\n'
  for l in $LEGS; do
    f="$OUT/logs/$l.txt"
    b=$(awk '$1=="B"{print $2}' "$f")
    ksum=$(awk '$1=="K"{s+=$3} END{print s}' "$f")
    ok=$([ -n "$b" ] && [ "$b" = "$ksum" ] && echo PASS || echo FAIL)
    printf '%s\tsteps_sum\t%s\tB=%s == sum of chunk rcs=%s\n' "$l" "$ok" "$b" "$ksum"
    s12=$(awk '$1=="S" && $2==12 {print $4}' "$f" | tr '\n' ',')
    fin=$(awk '$1=="F"{print $4}' "$f" | tr '\n' ',')
    ok=$([ -n "$s12" ] && [ "$s12" = "$fin" ] && echo PASS || echo FAIL)
    printf '%s\tone_call_equals_12_chunks\t%s\tF rows == S 12 rows, bitwise\n' "$l" "$ok"
    w4=$(awk '$1=="W" && $2==4 {print $4}' "$f" | tr '\n' ',')
    a4=$(awk '$1=="A" && $2==4 {print $3}' "$f")
    ok=$([ -n "$fin" ] && [ "$w4" = "$fin" ] && [ "$a4" = "$b" ] && echo PASS || echo FAIL)
    printf '%s\tcontrol_retraces\t%s\tA4 rc=%s == B, W4 rows == F rows\n' "$l" "$ok" "$a4"
  done
} > "$RES/loop.tsv"
cat "$RES/loop.tsv"

# --- trap.tsv ----------------------------------------------------------------
{
  printf 'id\tleg\tcase\tret\twrote_nothing\tverdict\n'
  for l in $LEGS; do
    base=$(awk '$1=="S" && $2==12 {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
    fin=$(awk '$1=="F"{print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
    for k in 0 1 2 3 4; do
      r=$(awk -v k=$k '$1=="A" && $2==k {print $3}' "$OUT/logs/$l.txt")
      w=$(awk -v k=$k '$1=="W" && $2==k {print $4}' "$OUT/logs/$l.txt" | tr '\n' ',')
      case $k in
        0) lr="iters=0"    ; exp=-1 ;; 1) lr="iters=-3"   ; exp=-1 ;;
        2) lr="gtol2=-1.0" ; exp=-1 ;; 3) lr="gtol2=NaN"  ; exp=-1 ;;
        *) lr="control"    ; exp=7  ;;
      esac
      if [ "$k" = 4 ]; then
        wn=$([ "$w" = "$fin" ] && echo "wrote (== F rows)" || echo UNEXPECTED)
        ok=$([ "$r" = "$exp" ] && [ "$w" = "$fin" ] && echo PASS || echo FAIL)
      else
        wn=$([ "$w" = "$base" ] && echo yes || echo "NO -- it wrote")
        ok=$([ "$r" = "$exp" ] && [ "$w" = "$base" ] && echo PASS || echo FAIL)
      fi
      printf 'nc%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$l" "$lr" "$r" "$wn" "$ok"
    done
  done
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
  for extra in 1 -6; do
    "$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" --trap "$extra" \
        > "$OUT/logs/wasm_trap$extra.out" 2>&1
    rc=$?
    line=$(grep -c 'TRAP.code=4' "$OUT/logs/wasm_trap$extra.out" || true)
    unr=$(grep -c UNREACHED "$OUT/logs/wasm_trap$extra.out" || true)
    ok=$([ "$rc" = 3 ] && [ "$line" = 1 ] && [ "$unr" = 0 ] && echo PASS || echo FAIL)
    printf 'len_trap%s\twasm32\textra=%s\texit=%s\ttrap4=%s unreached=%s\t%s\n' \
      "$extra" "$extra" "$rc" "$line" "$unr" "$ok"
  done
  if [ "$NO_DEVICE" != 1 ]; then
    # k_panic() surfaces as the fault handler's register dump; the FATAL ERROR
    # banner is not always flushed before QEMU is stopped, so the dump counts too.
    run_qemu m33trap qemu_m33_trap.log 'Faulting instruction|ZEPHYR FATAL ERROR|Halting system|UNREACHED'
    line=$(grep -c 'TRAP.code=4' "$RES/qemu_m33_trap.log" || true)
    unr=$(grep -c UNREACHED "$RES/qemu_m33_trap.log" || true)
    halt=$(grep -cE 'ZEPHYR FATAL ERROR|Halting system|Faulting instruction address' "$RES/qemu_m33_trap.log" || true)
    ok=$([ "$line" -ge 1 ] && [ "$unr" = 0 ] && [ "$halt" -ge 1 ] && echo PASS || echo FAIL)
    printf 'len_trap1\tm33\textra=1\tpanic\ttrap4=%s halt=%s unreached=%s\t%s\n' \
      "$line" "$halt" "$unr" "$ok"
  fi
} > "$RES/trap.tsv"
cat "$RES/trap.tsv"

# --- surface.tsv ---------------------------------------------------------------
{
  printf 'check\tvalue\tverdict\n'
  for t in host cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    n=$(awk -F'\t' '$1=="ALLOW" && $4=="platform extern declared by the profile"' \
        "$RES/undef.kern.$t.tsv" | wc -l | tr -d ' ')
    d=$(awk -F'\t' '$1=="DENY"' "$RES/undef.kern.$t.tsv" | wc -l | tr -d ' ')
    printf 'kern_undef.%s\textern_allows=%s deny=%s\t%s\n' "$t" "$n" "$d" \
      "$([ "$d" = 0 ] && echo PASS || echo FAIL)"
  done
  ex=$("$NM" --defined-only --extern-only \
       "$OUT/gen/grad.cortex-m33-zephyr.o" | awk 'NF==3{print $3}' | sort | tr '\n' ',')
  printf 'grad_exports\t%s\t%s\n' "$ex" \
    "$([ "$ex" = "spinel_grad_sq_hinge_loss,spinel_hvp_sq_hinge_loss," ] && echo PASS || echo FAIL)"
  # The LLVM release ships no obj2yaml (spinel-llvm read the Field: lines); node
  # lists the module's imports in the same order.
  imp=$("$NODE" -e 'const m = new WebAssembly.Module(require("fs").readFileSync(process.argv[1]));
    console.log(WebAssembly.Module.imports(m).map(i => i.name + ",").join(""))' "$OUT/gen/kern.wasm")
  printf 'wasm_imports\t%s\t%s\n' "$imp" \
    "$({ [ "$imp" = "spinel_trap,memory," ] || [ "$imp" = "spinel_trap," ]; } && echo PASS || echo FAIL)"
  u=$("$NM" --undefined-only "$OUT/gen/kern.wasm32-worker.o" \
      | awk '{print $2}' | sort | tr '\n' ',')
  printf 'kern_wasm_undef\t%s\t%s\n' "$u" \
    "$([ "$u" = "spinel_grad_sq_hinge_loss,spinel_hvp_sq_hinge_loss,spinel_trap," ] && echo PASS || echo FAIL)"
} > "$RES/surface.tsv"
cat "$RES/surface.tsv"

bad=$(cat "$RES/legs.tsv" "$RES/hvpsym.tsv" "$RES/loop.tsv" "$RES/trap.tsv" "$RES/surface.tsv" | awk -F'\t' '$0 ~ /\tFAIL(\t|$)/' | wc -l | tr -d ' ')
echo "run_gates: $bad failing row(s)"
[ "$bad" = 0 ]
