# E082 -- the kernel the Newton demo minimises.  STRICTLY convex (the
# quadratic anchor keeps the Hessian positive definite even where the
# quartic term flattens) and non-quadratic (so Newton's quadratic
# convergence is a measurable CLAIM, not a one-step triviality):
#
#     f(x) = sum [ (x_i - c_i)^4 + (x_i - c_i)^2 / 2 ]  +  sum (x_i - x_{i+1})^2
#
# grad_def with hvp: is the WHOLE point: the demo's optimiser never sees a
# Hessian matrix, only H.v products through the promoted surface.
require_relative "spinel/grad"

grad_def :quart, wrt: [:x], tol: 1.0e-6, hvp: true,
         probe: [[[0.9, -0.4, 1.6, 0.2, -1.1, 0.7], [0.3, -0.2, 1.0, 0.5, -0.6, 0.1], 6],
                 [[2.0, 2.0, 2.0, 2.0, 2.0, 2.0], [0.3, -0.2, 1.0, 0.5, -0.6, 0.1], 6]]
def quart(x, c, n)
  s = 0.0
  i = 0
  while i < n
    d = x[i] - c[i]
    s += d * d * d * d + 0.5 * d * d
    i += 1
  end
  i = 0
  while i < n - 1
    e = x[i] - x[i + 1]
    s += e * e
    i += 1
  end
  s
end

puts quart([0.9, -0.4, 1.6, 0.2, -1.1, 0.7],
           [0.3, -0.2, 1.0, 0.5, -0.6, 0.1], 6)
