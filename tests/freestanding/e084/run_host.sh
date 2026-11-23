#!/usr/bin/env bash
# E084 host -- the same problem through the host pipeline (grad_def with
# hvp: true, spinel-gradgen). Ported from spinel-llvm 463d49dd
# docs/experiments/results/E084/run_host.sh (the original is in oracle/).
#
# Checks: gradgen passes its own gates on host/host_kernel.rb (G1-G4, the
# forward gates, G5); host/host_newton.rb, the Ruby Newton-CG over the generated
# wrappers, converges below a gradient norm of 1e-7, and ends with the one-step
# kill a piecewise-quadratic objective gives (the last two gradient norms fall
# from above 1e-4 to below 1e-7). spinel-llvm computed that gate in inline
# Python; here in Ruby.
#
# Not run, being comparisons of the host pipeline with the freestanding one (two
# implementations): host_mirror.c's layered bitwise comparison with the native
# leg and its FMA attribution (which also needed unfuse_fmuladd.py, not
# imported), and the check that Ruby's step count equals the kernel's B row.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
: "${ENZYME:?set ENZYME to the Enzyme plugin built against LLVM 23.1.1 (tools/grad/README.md)}"
export LLVM_PREFIX ENZYME
need_gradgen
SPINEL=${SPINEL:-$REPO/vendor/spinel/bin/spinel}
HOSTW=$OUT/host
mkdir -p "$RES"
fs_fresh_workdir "$HOSTW"; mkdir -p "$HOSTW/spinel"
cp "$REPO/tools/grad/spinel/grad.rb" "$HOSTW/spinel/"
cp "$HERE/host/host_kernel.rb" "$HERE/host/host_newton.rb" "$HOSTW/"

T=$RES/host.tsv
printf 'check\tverdict\tdetail\n' > "$T"
echo "== gradgen on the host surface =="
if (cd "$HOSTW" && "$REPO/tools/grad/spinel-gradgen" host_kernel.rb -o out \
      --emit-ruby host_grad.gen.rb) > "$HOSTW/host_gates.txt" 2>&1; then rc=PASS; else rc=FAIL; fi
printf 'gradgen_host_gates\t%s\t%s\n' "$rc" "$(tail -1 "$HOSTW/host_gates.txt")" >> "$T"
[ "$rc" = PASS ] || { cat "$HOSTW/host_gates.txt"; cat "$T"; exit 1; }

echo "== the Ruby Newton-CG =="
(cd "$HOSTW" && "$SPINEL" host_newton.rb -o host_newton --link out/host_kernel_grad.o) > /dev/null
"$HOSTW/host_newton" > "$HOSTW/host_newton_trace.tsv"
ruby -e '
  kv = {}; gn = []
  File.foreach(ARGV[0]) do |line|
    c = line.chomp.split("\t")
    gn << Float(c[3]) if c[0] == "newton"
    c[1..].each { |t| k, v = t.split("=", 2); kv[k] = v } if c[0] == "#"
  end
  g = Float(kv.fetch("newton_gnorm"))
  puts ["ruby_converged", g < 1e-7 ? "PASS" : "FAIL", "#{kv["newton_steps"]} steps, gnorm #{kv["newton_gnorm"]}"].join("\t")
  t = gn.select(&:positive?).last(2)
  kill = t.size == 2 && t[0] > 1e-4 && t[1] < 1e-7
  puts ["one_step_kill", kill ? "PASS" : "FAIL", t.map { |v| format("%.3e", v) }.join(" -> ")].join("\t")
' "$HOSTW/host_newton_trace.tsv" >> "$T" || printf 'host_newton_trace\tFAIL\tunreadable\n' >> "$T"
cat "$T"
! grep -q '	FAIL	' "$T"
