# E082 -- a second-order optimiser IN RUBY over the promoted surface.
#
# Newton by conjugate gradients: the inner CG solves H p = -g using ONLY
# Hessian-vector products (hvp_quart), never a Hessian matrix -- exactly the
# access pattern Newton-CG / L-BFGS-class methods need, which is what P007
# Phase 4's HVP item is FOR.  The optimiser is ~40 lines of ordinary Ruby:
# no framework, no tape, no tensor type (P007 s"do not"), same bargain as
# E076's 11-line backtracking.
#
# Two claims, both printed as data and gated by newton_gate.py:
#   1. Newton converges to ||grad|| < 1e-7 in <= 8 outer iterations, and
#      the tail is QUADRATIC (5.3e-2 -> 2.8e-4 -> 1.2e-8: each exponent
#      roughly doubles).
#   2. Gradient descent with the same line search and THE SAME EVALUATION
#      BUDGET ends orders of magnitude short -- the second-order vocabulary
#      pays, on the same kernel, through the same objects.
require_relative "newton_grad.gen.rb"

grad_check_signatures!

N = 6
C = [0.3, -0.2, 1.0, 0.5, -0.6, 0.1]
X0 = [0.9, -0.4, 1.6, 0.2, -1.1, 0.7]

def dot(a, b)
  s = 0.0
  i = 0
  while i < a.length
    s += a[i] * b[i]
    i += 1
  end
  s
end

def gnorm(g)
  Math.sqrt(dot(g, g))
end

# ---- inner CG: solve H p = -g with H.v products only ----------------------
def cg_solve(x, g, evals)
  p = Array.new(N, 0.0)
  r = g.map { |v| -v }
  d = r.dup
  rs = dot(r, r)
  gbuf = Array.new(N, 0.0)
  hv = Array.new(N, 0.0)
  20.times do
    hvp_quart(x, C, N, d, gbuf, hv)
    evals[0] += 1
    a = rs / dot(d, hv)
    i = 0
    while i < N
      p[i] += a * d[i]
      r[i] -= a * hv[i]
      i += 1
    end
    rs2 = dot(r, r)
    break if rs2 < 1e-28
    b = rs2 / rs
    i = 0
    while i < N
      d[i] = r[i] + b * d[i]
      i += 1
    end
    rs = rs2
  end
  p
end

# ---- Newton-CG ------------------------------------------------------------
puts "method\titer\tf\tgnorm\tevals"
evals = [0]
x = X0.dup
g = Array.new(N, 0.0)
newton_iters = 0
newton_gnorms = []
16.times do |it|
  f = grad_quart(x, C, N, g)
  evals[0] += 1
  gn = gnorm(g)
  puts "newton\t#{it}\t#{f}\t#{gn}\t#{evals[0]}"
  newton_gnorms << gn
  newton_iters = it
  break if gn < 1.0e-7
  p = cg_solve(x, g, evals)
  # damped: full step unless it does not descend
  t = 1.0
  fx = f
  8.times do
    y = Array.new(N) { |i| x[i] + t * p[i] }
    fy = gdval_quart(y, C, N)
    evals[0] += 1
    if fy < fx
      x = y
      break
    end
    t *= 0.5
  end
end
newton_evals = evals[0]

# ---- gradient descent: same line search, same objects, SAME BUDGET --------
evals = [0]
x = X0.dup
gd_gn = 0.0
gd_it = 0
while evals[0] < newton_evals
  f = grad_quart(x, C, N, g)
  evals[0] += 1
  gd_gn = gnorm(g)
  t = 0.25
  8.times do
    y = Array.new(N) { |i| x[i] - t * g[i] }
    fy = gdval_quart(y, C, N)
    evals[0] += 1
    if fy < f
      x = y
      break
    end
    t *= 0.5
  end
  gd_it += 1
end
puts "gd\t#{gd_it}\t-\t#{gd_gn}\t#{evals[0]}"
puts "#\tnewton_iters=#{newton_iters}\tnewton_gnorm=#{newton_gnorms[-1]}\tnewton_evals=#{newton_evals}\tgd_gnorm=#{gd_gn}\tgd_evals=#{evals[0]}"
