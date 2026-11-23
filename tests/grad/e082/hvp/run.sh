#!/bin/sh
# E082 hvp -- the forward vocabulary (hvp:, jvp:) on grad_def, and Newton-CG
# over it. Ported from spinel-llvm 463d49dd docs/experiments/results/E082/hvp/run.sh.
#
# Checks: gradgen accepts hvp_vocab.rb and newton_kernel.rb with G1-G4, the
# forward gates and G5 green; newton_demo, which sees only H.v products through
# the generated wrappers, converges in at most 8 iterations to a gradient norm
# below 1e-7, its last three gradient norms fall at least quadratically, and at
# the same evaluation budget it ends more than 100 times below gradient descent
# (the Newton gate spinel-llvm computed in inline Python, here in Ruby).
#
# Not run: analytic_check.c, the closed-form Hessian written by hand (an
# oracle, kept in ../oracle/).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cd "$OUT"
"$GRADGEN" hvp_vocab.rb -o out > gates.txt 2>&1 && rc=0 || rc=1
result gradgen_hvp_vocab $rc "$(tail -1 gates.txt)"
"$GRADGEN" newton_kernel.rb -o nout --emit-ruby newton_grad.gen.rb > newton_gates.txt 2>&1 && rc=0 || rc=1
result gradgen_newton_kernel $rc "$(tail -1 newton_gates.txt)"
[ $rc = 0 ] || { cat newton_gates.txt; exit 1; }
"$SPINEL" newton_demo.rb -o newton_demo --link nout/newton_kernel_grad.o > /dev/null
./newton_demo > newton_trace.tsv && rc=0 || rc=1
result newton_demo_runs $rc "$(tail -1 newton_trace.tsv)"
ruby -e '
  kv = {}; gn = []
  File.foreach(ARGV[0]) do |line|
    c = line.chomp.split("\t")
    gn << Float(c[3]) if c[0] == "newton"
    c[1..].each { |t| k, v = t.split("=", 2); kv[k] = v } if c[0] == "#"
  end
  it = Integer(kv.fetch("newton_iters")); g = Float(kv.fetch("newton_gnorm"))
  puts ["newton_converged", (it <= 8 && g < 1e-7) ? "PASS" : "FAIL", "#{it} iters, gnorm #{kv["newton_gnorm"]}"].join("\t")
  t = gn.last(3)
  quad = t.each_cons(2).all? { |a, b| Math.log10(b).abs >= 1.5 * Math.log10(a).abs }
  puts ["quadratic_tail", quad ? "PASS" : "FAIL", t.map { |v| format("%.3e", v) }.join(" -> ")].join("\t")
  adv = Float(kv.fetch("gd_gnorm")) / g
  puts ["beats_gd_at_equal_budget", adv > 100.0 ? "PASS" : "FAIL",
        format("newton %s vs gd %s at %s evals (x%.3g)", kv["newton_gnorm"], kv["gd_gnorm"], kv["gd_evals"], adv)].join("\t")
' newton_trace.tsv >> "$OUT/result.tsv" || result newton_gate 1 "the trace could not be read"
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
