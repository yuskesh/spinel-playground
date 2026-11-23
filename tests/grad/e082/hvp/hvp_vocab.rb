# E082 -- the forward vocabulary ON the surface (P007 Phase 4).
#
# E078 s5 proved forward-over-reverse works on Spinel primals, from a
# self-contained shim appended OUTSIDE the surface (its hvp_kernel.rb has a
# long comment explaining why: G8 refuses `mode: :forward` and tools/grad was
# read-only for that experiment).  E082 promotes exactly that mechanism into
# `grad_def` keywords -- these declarations are still ordinary `:reverse`
# ones (G8 untouched, DRAFT record G9), and `hvp:`/`jvp:` add exports.
#
# The three targets are E078's, bodies unchanged (the duplication between
# chain_px and chain_gam_px is E078's measured constraint -- a target calling
# a target trips the pinned-callee root veto, results/E078/hvp/hvp_kernel.rb
# documents both refused tidier spellings):
#   cubic        -- Hessian known on paper: the analytic differential oracle
#   chain_px     -- LINEAR, H == 0 exactly: what G4H's zero-vs-broken
#                   distinction exists for (accepted only because the
#                   gradient is probe-independent, checked over 2 probes)
#   chain_gam_px -- E039's gamma tail: a Hessian that must NOT be zero
require_relative "spinel/grad"

grad_def :cubic, wrt: [:x], tol: 1.0e-6, hvp: true, jvp: true,
         probe: [[[0.7, -1.3, 0.4, 2.1], 4],
                 [[0.25, 0.5, -0.75, 1.0], 4]]
def cubic(x, n)
  s = 0.0
  i = 0
  while i < n
    v = x[i]
    s += v * v * v
    i += 1
  end
  i = 0
  while i < n - 1
    s += 2.0 * x[i] * x[i + 1]
    i += 1
  end
  s + Math.exp(x[0] * x[1])
end

grad_def :chain_px, wrt: [:x], tol: 1.0e-6, hvp: true,
         probe: [[[0.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 255.0,
                   12.0, 200.0, 7.0, 60.0, 33.0, 140.0, 90.0], 4, 4, 5],
                 [[3.0, 9.0, 27.0, 81.0, 243.0, 1.0, 5.0, 25.0, 125.0,
                   2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0], 4, 4, 10]]
def chain_px(x, h, w, p)
  py = p / w
  px = p - py * w
  acc = 0.0
  j = 0
  while j < 3
    yy = py + j - 1
    yy = 0 if yy < 0
    yy = h - 1 if yy > h - 1
    i = 0
    while i < 3
      xx = px + i - 1
      xx = 0 if xx < 0
      xx = w - 1 if xx > w - 1
      inn = 0.0
      b = 0
      while b < 3
        ay = yy + b - 1
        ay = 0 if ay < 0
        ay = h - 1 if ay > h - 1
        a = 0
        while a < 3
          ax = xx + a - 1
          ax = 0 if ax < 0
          ax = w - 1 if ax > w - 1
          inn += x[ay * w + ax] * (1.0 / 9.0)
          a += 1
        end
        b += 1
      end
      acc += inn * (1.0 / 9.0)
      i += 1
    end
    j += 1
  end
  acc
end

grad_def :chain_gam_px, wrt: [:x], tol: 1.0e-6, hvp: true,
         probe: [[[0.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 255.0,
                   12.0, 200.0, 7.0, 60.0, 33.0, 140.0, 90.0], 4, 4, 5,
                  0.45454545454545453],
                 [[3.0, 9.0, 27.0, 81.0, 243.0, 1.0, 5.0, 25.0, 125.0,
                   2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0], 4, 4, 10,
                  0.45454545454545453]]
def chain_gam_px(x, h, w, p, g)
  py = p / w
  px = p - py * w
  acc = 0.0
  j = 0
  while j < 3
    yy = py + j - 1
    yy = 0 if yy < 0
    yy = h - 1 if yy > h - 1
    i = 0
    while i < 3
      xx = px + i - 1
      xx = 0 if xx < 0
      xx = w - 1 if xx > w - 1
      inn = 0.0
      b = 0
      while b < 3
        ay = yy + b - 1
        ay = 0 if ay < 0
        ay = h - 1 if ay > h - 1
        a = 0
        while a < 3
          ax = xx + a - 1
          ax = 0 if ax < 0
          ax = w - 1 if ax > w - 1
          inn += x[ay * w + ax] * (1.0 / 9.0)
          a += 1
        end
        b += 1
      end
      acc += inn * (1.0 / 9.0)
      i += 1
    end
    j += 1
  end
  acc

  255.0 * Math.exp(g * Math.log(acc * (1.0 / 255.0)))
end

puts cubic([0.7, -1.3, 0.4, 2.1], 4)
puts chain_px([0.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 255.0,
               12.0, 200.0, 7.0, 60.0, 33.0, 140.0, 90.0], 4, 4, 5)
puts chain_gam_px([0.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 255.0,
                   12.0, 200.0, 7.0, 60.0, 33.0, 140.0, 90.0], 4, 4, 5,
                  1.0 / 2.2)
