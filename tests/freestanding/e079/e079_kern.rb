# E079 kernel file -- P007 Phase 3 (the gradient on every exit).
#
# One kernel world, four targets, and -- new in this experiment -- a GRADIENT
# that goes with it.  Every declaration below is a `freestanding_def`: no
# runtime, no allocator, no GC roots, boundary types only.  The extra line is
#
#     freestanding_grad_def :sq_hinge_loss, wrt: :w
#
# which asks tools/grad/spinel-gradfs to synthesise d(loss)/d(w) from the SAME
# LLVM IR the freestanding generator already emits, for the SAME profile.  The
# declaration is inert to `spinel-mlirgen --freestanding`: with it and without
# it the generated .mlir/.ll/.o are byte-identical (nonreg.tsv).
#
#   spinel-mlirgen e079_kern.rb --freestanding --profile P.yaml -o kern.o
#   spinel-gradfs  e079_kern.rb                --profile P.yaml -o build/
#
# ---------------------------------------------------------------------------
# THE SUBJECT: E066's gatekeeper scorer, calibrated on the edge.
#
# A linear scorer over four features decides bot / not-bot.  E076 demo B
# calibrated the same shape on the HOST, in f64, and baked integer weights back
# into the gatekeeper.  Here the whole loop -- score, loss, gradient, SGD step,
# re-score -- is f64 and freestanding, so it runs unchanged on the device
# (Cortex-M33 / RV32, soft float), on the edge (wasm32) and on the host.
#
# There is no quantisation step and no integer scorer.  E077 D-4 put f64 on
# the boundary; once the device can carry f64 the two-phase construction is
# not buying anything, and it would put a rounding step between "the edge
# calibrated" and "the device applies", which is exactly the place this
# experiment is trying to keep bit-exact.
#
# WHAT THE CALLER OWNS (E077's ownership direction, unchanged):
#   data   nrow rows of 5 doubles: x0 x1 x2 x3 y,  y in {-1.0, +1.0}
#   w      5 doubles: the four feature weights and the bias
#   g      5 doubles: the shadow the gradient is ASSIGNED into
#
# WHAT IS NOT HERE: the loop over SGD steps.  See E079 s3 -- the arithmetic of
# a step is all below, but the step-to-step loop has to call the Enzyme
# adjoint, and a freestanding kernel cannot call an external function until
# P003 Phase 4 (platform externs).  The driver holds that loop, which is
# exactly the shape E067 s3 arrived at for its sequential filter.
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"

# ---- 0. the contract version, at the boundary (E067 s4's practice) --------
freestanding_def :kern_version, params: [], returns: :i32
def kern_version
  79
end

# ---- A. the sample generator ----------------------------------------------
# The four runners do not RECEIVE the samples, they GENERATE them (E067 s1):
# there is no path along which the input could be corrupted, so a difference
# in the log is a difference in the computation.  `k` is the row index; the
# LCG is seeded from it so any row can be produced independently.
#
# The ground truth `y` is NOT linear in the features (the `0.6 * a * b` term),
# so a linear scorer cannot reach zero error.  A separable truth would make
# the calibration look better than calibration is.
# The LCG is `% 2147483648` of a multiply-add, written so that it gives the
# same rows at any Integer width (decision 0019, revised 2026-10-21). `m + m`
# is 2**31 in a 64-bit body, where nothing wraps; in a 32-bit body it wraps to
# -2**31, the floored `%` leaves a value in (-2**31, 0], and adding `m + m`
# again wraps it to the same non-negative residue, since 2**31 divides 2**32.
freestanding_def :gen_row, params: [[:f64_buf, :out], :len, :i32], returns: :i32, overflow: :wrap
def gen_row(dst, n, k)
  m = 1073741824
  s = (k * 1103515245 + 12345) % (m + m)
  if s < 0
    s = s + m + m
  end
  s = (s * 1103515245 + 12345) % (m + m)
  if s < 0
    s = s + m + m
  end
  a = (s % 2000 - 1000) / 1000.0
  s = (s * 1103515245 + 12345) % (m + m)
  if s < 0
    s = s + m + m
  end
  b = (s % 2000 - 1000) / 1000.0
  s = (s * 1103515245 + 12345) % (m + m)
  if s < 0
    s = s + m + m
  end
  c = (s % 2000 - 1000) / 1000.0
  s = (s * 1103515245 + 12345) % (m + m)
  if s < 0
    s = s + m + m
  end
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

# ---- B. the scorer and the verdict (what the DEVICE runs) -----------------
freestanding_def :score_row, params: [[:f64_buf, :in], :len, [:f64_buf, :in], :len],
                 returns: :f64
def score_row(row, nr, w, nw)
  w[0] * row[0] + w[1] * row[1] + w[2] * row[2] + w[3] * row[3] + w[4]
end

# 0 = true negative, 1 = FALSE POSITIVE, 2 = false negative, 3 = true positive.
# Returning the confusion cell rather than the verdict keeps the driver free of
# arithmetic: it only counts (E067 s3 -- the driver's step() contains no
# arithmetic at all, which is what makes replay trivial).
freestanding_def :outcome, params: [[:f64_buf, :in], :len, [:f64_buf, :in], :len],
                 returns: :i32
def outcome(row, nr, w, nw)
  z = w[0] * row[0] + w[1] * row[1] + w[2] * row[2] + w[3] * row[3] + w[4]
  y = row[4]
  if z > 0.0
    if y > 0.0
      3
    else
      1
    end
  else
    if y > 0.0
      2
    else
      0
    end
  end
end

# ---- C. the loss -- THE DIFFERENTIATED ONE --------------------------------
# Squared hinge, mean over rows.  Two reasons it is this and not a logistic
# loss: `libm: none` in every profile (there is no exp), and the squared hinge
# is C^1 everywhere, so the finite-difference gate has no kink to argue about
# (tools/grad/README, G3 "the kink is the writer's responsibility").
#
# `if t > 0.0` is a real branch, and it is the reason G4 has to exist: with
# weights that already separate the data every arm is dead and the gradient is
# identically zero, which is exactly the hole R013 s4.1 fell into.
freestanding_grad_def :sq_hinge_loss, wrt: :w, tol: 1.0e-6
freestanding_def :sq_hinge_loss, params: [[:f64_buf, :in], :len,
                                          [:f64_buf, :in], :len], returns: :f64
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

# ---- D. the SGD step ------------------------------------------------------
# The weight buffer is `:inout`: read and written, which E077 D-5 makes a
# COMPILE-time contract.  A step is one call; the loop over steps belongs to
# the caller (see the header of this file).
#
# THE LEARNING RATE IS ADMITTED, NOT ASSUMED.  `lr <= 0` is gradient ascent
# spelled as descent, `lr > 1` diverges on this loss, and a NaN lr turns every
# weight into NaN one step later and never comes back.  All three fail the
# same test, because NaN compares false against everything: the guard is
# `0 < lr <= 1`, and a rejected step returns -1 having written NOTHING.
# The alternative -- letting the driver check -- would put the admission rule
# in three languages instead of one (E067 s8's placement discipline).
freestanding_def :sgd_step, params: [[:f64_buf, :inout], [:f64_buf, :in], :len, :f64],
                 returns: :i32
def sgd_step(w, g, n, lr)
  if lr > 0.0 && lr <= 1.0
    i = 0
    while i < n
      w[i] = w[i] - lr * g[i]
      i += 1
    end
    n
  else
    -1
  end
end
