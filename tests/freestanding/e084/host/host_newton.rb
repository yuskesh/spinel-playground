# E084 -- E082's Newton-CG demo, on E084's PROBLEM: ordinary host Ruby over
# the promoted `hvp:` surface (newton_demo.rb's shape), minimising the same
# squared hinge on the same 64 generated samples from the same initial
# weights as the freestanding kernel.  This is the "the Ruby surface walks
# the same problem" half of the host oracle; the BITWISE half is
# host_mirror.c (this file prints decimals, and its gate is E082's: converge
# fast, quadratic tail, report the step count so it can be matched against
# the kernel's B row).
require_relative "host_grad.gen.rb"

grad_check_signatures!

N = 5
ND = 320

def gen_row_h(dst, k)
  s = (k * 1103515245 + 12345) % 2147483648
  s = (s * 1103515245 + 12345) % 2147483648
  a = (s % 2000 - 1000) / 1000.0
  s = (s * 1103515245 + 12345) % 2147483648
  b = (s % 2000 - 1000) / 1000.0
  s = (s * 1103515245 + 12345) % 2147483648
  c = (s % 2000 - 1000) / 1000.0
  s = (s * 1103515245 + 12345) % 2147483648
  d = (s % 2000 - 1000) / 1000.0
  dst[0] = a
  dst[1] = b
  dst[2] = c
  dst[3] = d
  z = 1.5 * a + 0.8 * b - 1.2 * c + 0.4 * d + 0.6 * a * b - 0.3
  if z > 0.0
    dst[4] = 1.0
  else
    dst[4] = -1.0
  end
  5
end

DATA = Array.new(ND, 0.0)
row = Array.new(5, 0.0)
r = 0
while r < 64
  gen_row_h(row, r)
  i = 0
  while i < 5
    DATA[r * 5 + i] = row[i]
    i += 1
  end
  r += 1
end

def dot(a, b)
  s = 0.0
  i = 0
  while i < a.length
    s += a[i] * b[i]
    i += 1
  end
  s
end

# ---- inner CG: H p = -g with H.v products only (e084_kern.rb sN2's loop) --
def cg_solve(w, g, evals)
  p = Array.new(N, 0.0)
  r = Array.new(N, 0.0)
  d = Array.new(N, 0.0)
  i = 0
  while i < N
    r[i] = 0.0 - g[i]
    d[i] = r[i]
    i += 1
  end
  rs = dot(r, r)
  gbuf = Array.new(N, 0.0)
  hv = Array.new(N, 0.0)
  cg = 0
  while cg < 20
    hvp_sq_hinge_loss(DATA, ND, w, N, d, gbuf, hv)
    evals[0] += 1
    a = rs / dot(d, hv)
    i = 0
    while i < N
      p[i] += a * d[i]
      r[i] -= a * hv[i]
      i += 1
    end
    rs2 = dot(r, r)
    break if rs2 < 1.5e-28
    b = rs2 / rs
    i = 0
    while i < N
      d[i] = r[i] + b * d[i]
      i += 1
    end
    rs = rs2
    cg += 1
  end
  p
end

# ---- Newton-CG ------------------------------------------------------------
puts "method\titer\tf\tgnorm\tevals"
evals = [0]
w = [0.2, -0.1, 0.3, 0.0, 0.5]
g = Array.new(N, 0.0)
newton_steps = 0
gnorms = []
12.times do |it|
  f = grad_sq_hinge_loss(DATA, ND, w, N, g)
  evals[0] += 1
  gn = Math.sqrt(dot(g, g))
  puts "newton\t#{it}\t#{f}\t#{gn}\t#{evals[0]}"
  gnorms << gn
  break if dot(g, g) <= 1.0e-14
  p = cg_solve(w, g, evals)
  t = 1.0
  fx = f
  gs = Array.new(N, 0.0)
  8.times do
    y = Array.new(N) { |i| w[i] + t * p[i] }
    fy = grad_sq_hinge_loss(DATA, ND, y, N, gs)
    evals[0] += 1
    if fy < fx
      w = y
      break
    end
    t = t / 2.0
  end
  newton_steps = it + 1
end
puts "#\tnewton_steps=#{newton_steps}\tnewton_gnorm=#{gnorms[-1]}\tnewton_evals=#{evals[0]}"
