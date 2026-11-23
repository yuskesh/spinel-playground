# E076 -- the subject of the lane-entrance measurement.  ONE source text.
#
# `spinel-gradgen` compiles this file with `spinel -S` exactly once and takes
# TWO outputs out of the single module that emission produces:
#
#   exit 1  `sp_twin` itself, re-exported as `spg_val_twin`
#   exit 2  `@diffesp_twin`, the adjoint Enzyme synthesised FROM that same
#           `sp_twin`
#
# twin_app.rb then textually requires this same file, so the program's own
# copy of `twin` and the copy inside the gradient object have one source.
# Comparing them bit for bit is what makes "the differentiation pipeline --
# the pin, the GC-root elision, Enzyme, internalize -- did not change the
# function" a measurement rather than an assumption.
require_relative "spinel/grad"

grad_def :twin, wrt: [:a, :b], tol: 1.0e-6,
         probe: [[2.0, -0.5, 0.25], [0.75, 1.5, -0.5], [3.5, 0.125, 1.0]]
def twin(a, b, c)
  s = 0.0
  i = 0
  while i < 12
    t = a * Math.exp(b * 0.125) + c
    s += t * t / (1.0 + t * t)
    b = b + 0.0625
    i += 1
  end
  s
end
