# E083 kernel file -- P007/P003 合流 (the optimizer loop INSIDE the kernel).
#
# E079's kernel, verbatim (sections A-D are byte-for-byte the arithmetic of
# e079_kern.rb -- that is the point: the claim "the loop moved into the kernel
# and nothing else changed" is only measurable if nothing else changed), plus
# the one thing E079 measured it could not write (its s3, reject rows b04/b05):
#
#   ---- E. the calibration loop --------------------------------------------
#
# The loop calls `grad_loss(...)` -- the Enzyme adjoint spinel-gradfs
# synthesises -- through the platform-extern mechanism of E081, extended by
# this experiment to carry BUFFER parameters (profile *-e083.yaml, decision
# record D-10 draft).  E079's two obstacles, named there as
#   b04  "call to 'spinel_grad_sq_hinge_loss', which is not a top-level method"
#   b05  "a buffer and its :len do not cross a call"
# are closed by E081 (the call) and E083 (the buffer), respectively.  The
# step-to-step loop control that E079 left in the C/JS drivers is the `while`
# below -- ordinary Ruby, inside the freestanding subset.
#
#   spinel-mlirgen e083_kern.rb --freestanding --profile P-e083.yaml -o kern.o
#   spinel-gradfs  e083_kern.rb --profile P-e083.yaml --grads-only -o build/
#
# The kernel object IMPORTS spinel_grad_sq_hinge_loss (undef-check: "platform
# extern declared by the profile"); the gradfs object DEFINES it; the platform
# links the two, which is layer 3 doing exactly what it always does.
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"

# ---- 0. the contract version, at the boundary (E067 s4's practice) --------
freestanding_def :kern_version, params: [], returns: :i32
def kern_version
  83
end

# ---- A. the sample generator (E079 sA, verbatim) --------------------------
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

# ---- B. the scorer and the verdict (E079 sB, verbatim) --------------------
freestanding_def :score_row, params: [[:f64_buf, :in], :len, [:f64_buf, :in], :len],
                 returns: :f64
def score_row(row, nr, w, nw)
  w[0] * row[0] + w[1] * row[1] + w[2] * row[2] + w[3] * row[3] + w[4]
end

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

# ---- C. the loss -- THE DIFFERENTIATED ONE (E079 sC, verbatim) ------------
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

# ---- D. the SGD step (E079 sD, verbatim) ----------------------------------
# Kept even though section E subsumes it: the E079 drivers called this entry
# once per step, and keeping it lets the non-regression say "the old shape
# still exists next to the new one" rather than "the old shape was replaced".
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

# ---- E. the calibration loop -- WHAT E079 COULD NOT WRITE -----------------
# The whole SGD loop, inside the freestanding subset.  Per step it (1) calls
# the adjoint through the platform extern -- which ASSIGNS the gradient into
# `g` (the gradfs shim zeroes the shadow first, E079's contract) -- and then
# (2) applies exactly the arithmetic of `sgd_step` above (`w[i] - lr * g[i]`,
# same order, same expressions).  So `calibrate(..., steps: 40, lr)` must be
# bit-identical to forty driver-side grad+sgd_step rounds -- E079's stored
# weight stream is the oracle for that, row by row (run_gates.sh, e079.tsv).
#
# The learning-rate guard is E079 sD's, checked ONCE at entry: lr is a scalar,
# no step changes it, and a refused call must write NOTHING -- checking per
# step would be forty copies of the same comparison of the same value.
#
# `w` is :inout (the loop reads it, the update writes it); `g` is :inout too,
# NOT :out -- the extern writes it, but the update READS it back, and a read
# of an :out buffer is a compile-time direction violation (E077 D-5).  The
# extern's own declaration says [f64_buf, out] for the shadow; passing an
# :inout buffer there is fine (writability is what :out needs, and :inout
# licenses it), and the reject table has the arms that are not fine.
freestanding_def :calibrate,
                 params: [[:f64_buf, :in], :len, [:f64_buf, :inout],
                          [:f64_buf, :inout], :len, :i32, :f64],
                 returns: :i32
def calibrate(data, nd, w, g, nw, steps, lr)
  if lr > 0.0 && lr <= 1.0
    t = 0
    while t < steps
      grad_loss(data, nd, w, g, nw)
      i = 0
      while i < nw
        w[i] = w[i] - lr * g[i]
        i += 1
      end
      t += 1
    end
    steps
  else
    -1
  end
end

# ---- F. the length-check probe (E083 D-10 draft, the runtime half) --------
# The extern boundary's one RUNTIME check: the length the kernel passes must
# not license the extern beyond the buffers the kernel itself was handed
# (0 <= n <= declared len, one unsigned compare per buffer in the run, trap
# code 4).  `extra` makes the same entry the control and both broken arms:
#   extra = 0        -> in range, returns the loss (the adjoint's primal value)
#   extra = 1        -> nw+1 > len(w): trap 4 before the call
#   extra = -(nw+1)  -> negative length: the same unsigned compare, trap 4
freestanding_def :grad_probe,
                 params: [[:f64_buf, :in], :len, [:f64_buf, :inout],
                          [:f64_buf, :inout], :len, :i32],
                 returns: :f64
def grad_probe(data, nd, w, g, nw, extra)
  grad_loss(data, nd, w, g, nw + extra)
end
