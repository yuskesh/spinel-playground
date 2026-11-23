# E084 -- the HOST side of the same problem (the oracle's subject).
#
# The body is e084_kern.rb's squared hinge, VERBATIM (same expressions, same
# order); the declaration is E082's confirmed G9 spelling (`hvp:` on
# `grad_def`).  spinel-gradgen turns this into spg_val_/spg_grad_/spg_hvp_
# exports through the HOST pipeline: Spinel's generated C, clang -O2 on the
# host, Enzyme on that module -- a completely different provenance from
# spinel-mlirgen's freestanding IR, which is exactly what the host
# differential is for: same mathematics, two independent compilation paths,
# compared bitwise and layer by layer (host/host_mirror.c, host.tsv).
require_relative "spinel/grad"

grad_def :sq_hinge_loss, wrt: [:w], tol: 1.0e-6, hvp: true,
         probe: [[[0.5, -0.3, 0.2, 0.8, 1.0,
                   -0.4, 0.9, -0.2, 0.1, -1.0], 10,
                  [0.2, -0.1, 0.3, 0.0, 0.5], 5],
                 [[0.1, 0.7, -0.6, 0.3, -1.0,
                   -0.8, -0.2, 0.5, 0.9, 1.0], 10,
                  [1.0, 0.5, -0.5, 0.2, 0.0], 5]]
def sq_hinge_loss(data, nd, w, nw)
  rows = nd / 5
  total = 0.0
  r = 0
  while r < rows
    b = r * 5
    z = w[0] * data[b] + w[1] * data[b + 1] + w[2] * data[b + 2] +
        w[3] * data[b + 3] + w[4]
    t = 1.0 - data[b + 4] * z
    if t > 0.0
      total = total + t * t
    end
    r += 1
  end
  total / rows
end

puts sq_hinge_loss([0.5, -0.3, 0.2, 0.8, 1.0, -0.4, 0.9, -0.2, 0.1, -1.0], 10,
                   [0.2, -0.1, 0.3, 0.0, 0.5], 5)
