#!/usr/bin/env bash
# E084 host oracle -- the same problem, through the HOST pipeline.
#
#   1. spinel-gradgen on host/host_kernel.rb (the E082 G9 surface: grad_def
#      with hvp: true; body verbatim from e084_kern.rb).  Its own gates
#      (G1..G4 + G3H/GDOT/GSYM/G4H + G5) run here -- host_gates.txt.
#   2. host/host_mirror.c -- the BITWISE half: the kernel's Newton-CG
#      mirrored line for line over the spg_* exports, printing the same
#      stream as the freestanding legs.  host.tsv holds the layered
#      comparison (primal / gradient / hvp / trajectory) against the native
#      leg's stream; where the bits split, the FIRST layer that splits is
#      the finding.
#   3. host/host_newton.rb -- the RUBY half (E082 newton_demo's shape): the
#      surface itself walks the problem; gated on convergence shape and on
#      the step count matching the kernel's B row.
set -euo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e084/oracle/run_host.orig.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
OUT=${OUT:-$SCRATCH/e084/work}
HOSTW=$SCRATCH/e084/host
LLVM=/opt/homebrew/opt/llvm/bin

rm -rf "$HOSTW"
mkdir -p "$HOSTW/spinel"
cp "$REPO/tools/grad/spinel/grad.rb" "$HOSTW/spinel/"
cp "$HERE/host/host_kernel.rb" "$HERE/host/host_newton.rb" "$HOSTW/"

echo "== 1: gradgen on the host surface (G1..G4 + forward gates + G5) =="
(cd "$HOSTW" && "$REPO/tools/grad/spinel-gradgen" host_kernel.rb -o out \
    --emit-ruby host_grad.gen.rb) > "$HERE/host_gates.txt" 2>&1 || {
  cat "$HERE/host_gates.txt"; exit 1; }
tail -1 "$HERE/host_gates.txt"
cp "$HOSTW/out/gates.tsv" "$HERE/host_gradgen_gates.tsv"

echo "== 2: the bitwise mirror =="
# linked like E082's analytic_check: the whole diff MODULE (the generated
# program TU, Enzyme's products included) + the runtime archive
"$LLVM/clang" -O2 -Wno-everything -o "$HOSTW/host_mirror" \
    "$HERE/host/host_mirror.c" "$HOSTW/out/host_kernel_diff.ll" \
    -L "$REPO/vendor/spinel/lib" -lspinel_rt -lm
"$HOSTW/host_mirror" > "$HOSTW/host_stream.txt"
cp "$HOSTW/host_stream.txt" "$HERE/host_stream.txt"

python3 - "$OUT/logs/native.txt" "$HOSTW/host_stream.txt" > "$HERE/host.tsv" <<'EOF'
# The layered host differential: one row per stream row that exists on both
# sides, grouped into layers; the summary names the FIRST layer where the
# bits split (or BIT-IDENTICAL).
import sys
def read(p):
    rows = {}
    order = []
    for ln in open(p):
        ps = ln.split()
        if not ps or ps[0].startswith("#") or ps[0] in ("K", "B", "A"):
            # keep the integer rows too, as strings
            if ps and ps[0] in ("K", "B"):
                key = tuple(ps[:-1]); rows[key] = ps[-1]; order.append(key)
            continue
        key = tuple(ps[:-1])
        rows[key] = ps[-1]
        order.append(key)
    return rows, order
nat, order = read(sys.argv[1])
hst, _ = read(sys.argv[2])
LAYERS = [
    ("primal",     lambda k: k[0] == "L" and k[1] == "0"),
    ("gradient",   lambda k: k[0] in ("G0",) or (k[0] == "N" and k[1] == "0")),
    ("hvp",        lambda k: k[0] in ("V", "Vr", "U", "Z")),
    ("trajectory", lambda k: k[0] in ("K", "B", "F", "#final")
                             or (k[0] in ("L", "N", "S") and k[1] != "0")),
]
def layer_of(k):
    for name, f in LAYERS:
        if f(k):
            return name
    return None
stats = {name: [0, 0, None] for name, _ in LAYERS}   # same, differ, first
print("row\tlayer\tnative\thost\tverdict")
for k in order:
    lay = layer_of(k)
    if lay is None or k not in hst:
        continue
    a, b = nat[k], hst[k]
    v = "SAME" if a == b else "DIFFER"
    st = stats[lay]
    if v == "SAME":
        st[0] += 1
    else:
        st[1] += 1
        if st[2] is None:
            st[2] = " ".join(k)
    print("%s\t%s\t%s\t%s\t%s" % (" ".join(k), lay, a, b, v))
first_split = None
for name, _ in LAYERS:
    s, d, f = stats[name]
    print("#layer.%s\t%d same\t%d differ\tfirst=%s" % (name, s, d, f or "-"))
    if d and first_split is None:
        first_split = name
tot_d = sum(v[1] for v in stats.values())
print("#summary\t%s" % ("BIT-IDENTICAL (all layers)" if tot_d == 0
                        else "FIRST-SPLIT-LAYER=%s (%d differing rows)"
                        % (first_split, tot_d)))
EOF
grep '^#' "$HERE/host.tsv"

echo "== 2b: attribution -- is the split FMA contraction, and nothing else? =="
# The ladder: (a) stock host module + stock mirror -> host.tsv above (the
# split as a user of both pipelines would see it); (b) unfuse the module's
# llvm.fmuladd sites (the other ALLOWED lowering of the same intrinsic) and
# compile the mirror's own loop with -ffp-contract=off (the kernel loop it
# mirrors carries no contract licence, G5); if every shared row is then
# bit-identical, the split is attributed to FMA -- dynamically, not by
# staring at IR (E062).
NFMA_HOST=$(grep -c 'call[^"]*@llvm\.fmuladd\.f64' "$HOSTW/out/host_kernel_diff.ll" || true)
NFMA_KERN=$(grep -c 'llvm\.fmuladd' "$OUT/gen/kern.arm64-host.ll" || true)
NFMA_GRAD=$(grep -c 'llvm\.fmuladd' "$OUT/gen/grad.arm64-host.min.ll" || true)
python3 "$HERE/host/unfuse_fmuladd.py" "$HOSTW/out/host_kernel_diff.ll" \
    "$HOSTW/out/host_kernel_diff_unfused.ll"
"$LLVM/clang" -O2 -Wno-everything -ffp-contract=off -o "$HOSTW/host_mirror_unfused" \
    "$HERE/host/host_mirror.c" "$HOSTW/out/host_kernel_diff_unfused.ll" \
    -L "$REPO/vendor/spinel/lib" -lspinel_rt -lm
"$HOSTW/host_mirror_unfused" > "$HOSTW/host_stream_unfused.txt"
{
  printf 'check\tvalue\tverdict\n'
  printf 'fmuladd_sites.host_module\t%s\t%s\n' "$NFMA_HOST" \
    "$([ "$NFMA_HOST" -gt 0 ] && echo "INFO (clang default -ffp-contract=on)" || echo "INFO")"
  printf 'fmuladd_sites.kern_ll\t%s\t%s\n' "$NFMA_KERN" \
    "$([ "$NFMA_KERN" = 0 ] && echo PASS || echo FAIL)"
  printf 'fmuladd_sites.grad_min_ll\t%s\t%s\n' "$NFMA_GRAD" \
    "$([ "$NFMA_GRAD" = 0 ] && echo PASS || echo FAIL)"
  stock_split=$(awk -F'\t' '/^#summary/{print $2}' "$HERE/host.tsv")
  printf 'stock_vs_native\t%s\tINFO\n' "$stock_split"
  read -r shared differ <<EOF2
$(python3 - "$OUT/logs/native.txt" "$HOSTW/host_stream_unfused.txt" <<'PYEOF'
import sys
def read(p):
    rows = {}
    for ln in open(p):
        ps = ln.split()
        if not ps: continue
        rows[tuple(ps[:-1])] = ps[-1]
    return rows
nat, hst = read(sys.argv[1]), read(sys.argv[2])
shared = [k for k in nat if k in hst]
differ = [k for k in shared if nat[k] != hst[k]]
print(len(shared), len(differ))
PYEOF
)
EOF2
  printf 'unfused_vs_native\t%s shared rows, %s differ\t%s\n' "$shared" "$differ" \
    "$([ "$differ" = 0 ] && echo PASS || echo FAIL)"
} > "$HERE/host_fma.tsv"
cat "$HERE/host_fma.tsv"

echo "== 3: the Ruby Newton-CG on the same problem =="
(cd "$HOSTW" && "$REPO/vendor/spinel/bin/spinel" host_newton.rb -o host_newton \
    --link out/host_kernel_grad.o) > /dev/null
"$HOSTW/host_newton" > "$HERE/host_newton_trace.tsv"
tail -2 "$HERE/host_newton_trace.tsv"

python3 - "$HERE/host_newton_trace.tsv" "$OUT/logs/native.txt" > "$HERE/host_newton.tsv" <<'EOF'
import math, sys
kv = {}
gn = []
for line in open(sys.argv[1]):
    c = line.rstrip("\n").split("\t")
    if c[0] == "newton":
        gn.append(float(c[3]))
    if c[0] == "#":
        for tok in c[1:]:
            k, _, v = tok.partition("=")
            kv[k] = v
kern_b = None
for line in open(sys.argv[2]):
    p = line.split()
    if p and p[0] == "B":
        kern_b = int(p[1])
rows = []
steps = int(kv["newton_steps"])
rows.append(("ruby_converged", "%d steps, gnorm %s" % (steps, kv["newton_gnorm"]),
             "OK" if float(kv["newton_gnorm"]) < 1e-7 else "RED"))
# NOT E082's doubling-exponent tail: a squared hinge is PIECEWISE QUADRATIC,
# so once the active set stabilises the objective is exactly quadratic and a
# CG-solved Newton step lands on the minimiser in ONE step -- the honest
# signature here is a single >6-orders drop at the end, not a doubling tail.
t = [g for g in gn if g > 0][-2:]
kill = len(t) == 2 and t[0] > 1e-4 and t[1] < 1e-7
rows.append(("one_step_kill", " -> ".join("%.3e" % v for v in t),
             "OK" if kill else "RED"))
rows.append(("steps_match_kernel", "ruby %d vs kernel B %s" % (steps, kern_b),
             "OK" if kern_b == steps else "RED"))
print("check\tdetail\tverdict")
for r in rows:
    print("\t".join(r))
EOF
cat "$HERE/host_newton.tsv"
if grep -q RED "$HERE/host_newton.tsv"; then exit 1; fi
echo "run_host: done"
