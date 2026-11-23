#!/bin/sh
# E082 -- HVP/JVP promoted to the grad_def surface (P007 Phase 4).
#
#   1. spinel-gradgen on hvp_vocab.rb: the G1..G4 gates PLUS the new forward
#      gates (G3F/GXF for jvp, G3H/GDOT/GSYM/G4H for hvp) and G5 (no
#      fast-math flag on any adjoint -- E079's determinism gate, applied to
#      the forward path as the P007 Phase 4 brief requires).
#   2. analytic_check: the closed-form Hessian of `cubic`, column by column
#      through the PRODUCT export spg_hvp_cubic -- the same identity E078
#      s5.2 measured from its out-of-surface shim at rel 0.000e+00.
set -e
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tests/grad/e082/oracle/hvp/run.orig.sh whole || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../../.." && pwd)
LLVM=/opt/homebrew/opt/llvm/bin
cd "$HERE"
rm -rf out spinel
mkdir -p spinel
cp "$ROOT/tools/grad/spinel/grad.rb" spinel/

echo "== 1: gradgen (G1..G4 + forward gates + G5) =="
"$ROOT/tools/grad/spinel-gradgen" hvp_vocab.rb -o out > gates.txt
tail -1 gates.txt

echo "== 2: analytic Hessian oracle through the product exports =="
$LLVM/clang -O2 -Wno-everything analytic_check.c out/hvp_vocab_diff.ll \
  -o out/analytic_check -lm \
  -L "$ROOT/vendor/spinel/lib" -lspinel_rt
./out/analytic_check > e082_hvp_analytic.tsv
tail -1 e082_hvp_analytic.tsv

echo "== 3: Newton-CG in Ruby over the promoted surface =="
# The optimiser (newton_demo.rb) sees only H.v products through the .gen.rb
# wrappers -- the access pattern second-order methods need, which is what
# the HVP item of P007 Phase 4 is FOR.  Gradient descent gets the same line
# search, the same objects and THE SAME evaluation budget.
"$ROOT/tools/grad/spinel-gradgen" newton_kernel.rb -o nout \
  --emit-ruby newton_grad.gen.rb > newton_gates.txt
tail -1 newton_gates.txt
"$ROOT/vendor/spinel/bin/spinel" newton_demo.rb -o newton_demo \
  --link nout/newton_kernel_grad.o > /dev/null
./newton_demo > newton_trace.tsv
tail -1 newton_trace.tsv
python3 - <<'PYEOF' > e082_newton.tsv
# the Newton gate: 4 rows from newton_trace.tsv
import math
kv = {}
gn = []
for line in open("newton_trace.tsv"):
    c = line.rstrip("\n").split("\t")
    if c[0] == "newton":
        gn.append(float(c[3]))
    if c[0] == "#":
        for tok in c[1:]:
            k, _, v = tok.partition("=")
            kv[k] = v
rows = []
it = int(kv["newton_iters"])
rows.append(("newton_converged", "%s iters, gnorm %s" % (it, kv["newton_gnorm"]),
             "OK" if it <= 8 and float(kv["newton_gnorm"]) < 1e-7 else "RED"))
# quadratic tail: over the last three gnorms the exponent must at least
# double up to slack (|log g_{k+1}| >= 1.5 |log g_k|)
t = gn[-3:]
quad = all(abs(math.log10(t[i + 1])) >= 1.5 * abs(math.log10(t[i]))
           for i in range(len(t) - 1))
rows.append(("quadratic_tail", " -> ".join("%.3e" % v for v in t),
             "OK" if quad else "RED"))
adv = float(kv["gd_gnorm"]) / float(kv["newton_gnorm"])
rows.append(("beats_gd_at_equal_budget",
             "newton %s vs gd %s at %s evals (x%.3g)" %
             (kv["newton_gnorm"], kv["gd_gnorm"], kv["gd_evals"], adv),
             "OK" if adv > 100.0 else "RED"))
print("check\tdetail\tverdict")
for r in rows:
    print("\t".join(r))
PYEOF
cat e082_newton.tsv
if grep -q RED e082_newton.tsv; then exit 1; fi

cp out/gates.tsv e082_hvp_gates.tsv
cp out/targets.tsv e082_hvp_targets.tsv
cp out/fwd_targets.tsv e082_hvp_fwd_targets.tsv
cp out/build.tsv e082_hvp_build.tsv
cp nout/gates.tsv e082_newton_gates.tsv
echo "done: e082_hvp_{gates,targets,fwd_targets,build,analytic}.tsv + e082_newton{,_gates}.tsv"
