# E084 kernel file -- the SECOND-ORDER calibration loop inside the kernel
# (E083's handover item 2: "freestanding HVP -- no obstacle is left, only the
# amount of work").
#
# Sections A and C are E079/E083's arithmetic, verbatim (the loss under
# calibration is the same squared hinge, on the same 64 generated samples,
# from the same initial weights -- so every number here is comparable with the
# stored E079/E083 streams and with the E082-style HOST Newton-CG oracle).
# What is new:
#
#   - `freestanding_grad_def :sq_hinge_loss, ..., hvp: true` -- the E082 G9
#     spelling on the FREESTANDING declaration (draft G9-fs; the host-side
#     `grad_def` keyword is confirmed G9, this file's use of it on
#     `freestanding_grad_def` is the draft this experiment submits).
#     spinel-gradfs now synthesises spinel_hvp_sq_hinge_loss next to
#     spinel_grad_sq_hinge_loss: forward-over-reverse (E078 s5 / E082 s3.4),
#     same object, same --grads-only discipline.
#
#   - `newton_calibrate` -- Newton-CG in the freestanding subset.  The inner
#     CG solves H p = -g using ONLY the hvp extern (never a Hessian matrix);
#     the damped step is E082 newton_demo.rb's (t=1, halve up to 8 times
#     until f(y) < f(x)).  Every scratch vector is a caller-owned boundary
#     buffer: the subset has no Array.new and no local arrays, and D-10 only
#     lets the kernel pass ITS OWN boundary buffers to an extern -- so the
#     boundary carries eight nw-sized buffers, and that is a finding, not an
#     inconvenience (see the reject corpus: sqrt/Array.new/map stay refused,
#     which is WHY the stopping rule below is on ||g||^2, not ||g||).
#
# NOTE the mirror discipline: the HOST oracle (host/host_newton.rb) uses the
# same expressions in the same order, including `0.0 - g[i]` (never unary
# minus: 0.0 - 0.0 is +0.0 while -(0.0) is -0.0, and the streams are compared
# BITWISE).
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"

# ---- 0. the contract version, at the boundary (E067 s4's practice) --------
freestanding_def :kern_version, params: [], returns: :i32
def kern_version
  84
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

# ---- C. the loss -- THE DIFFERENTIATED ONE (E079 sC, verbatim body) -------
# hvp: true is the one new word (draft G9-fs).  Everything else -- wrt:, tol:,
# the boundary, the body -- is E079/E083's, byte for byte.
freestanding_grad_def :sq_hinge_loss, wrt: :w, tol: 1.0e-6, hvp: true
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

# ---- N1. the gradient-norm probe ------------------------------------------
# ||grad f(w)||^2, computed IN the kernel (the driver holds no arithmetic on
# the quantities under test -- E079's discipline).  This is also the honest
# form of the stopping quantity: Math.sqrt is not in the freestanding subset
# (reject n1), so the kernel's stopping rule is on the SQUARE, and so is the
# stream the four legs must agree on.
freestanding_def :grad_norm2,
                 params: [[:f64_buf, :in], :len, [:f64_buf, :inout],
                          [:f64_buf, :inout], :len],
                 returns: :f64
def grad_norm2(data, nd, w, g, nw)
  grad_loss(data, nd, w, g, nw)
  s = 0.0
  i = 0
  while i < nw
    s = s + g[i] * g[i]
    i += 1
  end
  s
end

# ---- N2. Newton-CG -- the second-order loop, inside the kernel ------------
# Buffers: data (in, nd) | w g gs hv p r d y (inout, all governed by nw).
#   w   the weights (read and updated)
#   g   the gradient at w                (assigned by the grad extern)
#   gs  gradient scratch                 (hvp's g output / f(y) probes)
#   hv  H.d                              (assigned by the hvp extern)
#   p   the CG solution   (H p = -g)
#   r   the CG residual
#   d   the CG direction  (this is what the hvp extern differentiates along)
#   y   the trial point of the damped step
# Returns the number of Newton steps actually taken (0 = already converged),
# or -1 -- and then it has written NOTHING -- for a refused iters/gtol2.
freestanding_def :newton_calibrate,
                 params: [[:f64_buf, :in], :len,
                          [:f64_buf, :inout], [:f64_buf, :inout],
                          [:f64_buf, :inout], [:f64_buf, :inout],
                          [:f64_buf, :inout], [:f64_buf, :inout],
                          [:f64_buf, :inout], [:f64_buf, :inout],
                          :len, :i32, :f64],
                 returns: :i32
def newton_calibrate(data, nd, w, g, gs, hv, p, r, d, y, nw, iters, gtol2)
  if iters > 0 && gtol2 >= 0.0
    stepped = 0
    it = 0
    while it < iters
      f = grad_loss(data, nd, w, g, nw)
      gg = 0.0
      i = 0
      while i < nw
        gg = gg + g[i] * g[i]
        i += 1
      end
      if gg > gtol2
        # ---- inner CG: solve H p = -g with H.v products only (E082 s3.3) --
        i = 0
        while i < nw
          p[i] = 0.0
          r[i] = 0.0 - g[i]
          d[i] = r[i]
          i += 1
        end
        rs = 0.0
        i = 0
        while i < nw
          rs = rs + r[i] * r[i]
          i += 1
        end
        cg = 0
        cgdone = 0
        while cg < 20 && cgdone == 0
          hvp_loss(data, nd, w, d, gs, hv, nw)
          dh = 0.0
          i = 0
          while i < nw
            dh = dh + d[i] * hv[i]
            i += 1
          end
          a = rs / dh
          i = 0
          while i < nw
            p[i] = p[i] + a * d[i]
            r[i] = r[i] - a * hv[i]
            i += 1
          end
          rs2 = 0.0
          i = 0
          while i < nw
            rs2 = rs2 + r[i] * r[i]
            i += 1
          end
          # 1.5e-28, not 1e-28: mlirgen prints the float literal via repr and
          # MLIR refuses `1e-28` (no decimal point) as a constant -- a LOUD
          # build error, recorded; tools/mlir is out of scope this experiment
          # (E085 running in parallel), so the threshold is one whose repr
          # carries a dot.  The value is a guard against dividing by a tiny
          # rs, nothing more; the host mirror uses the same number.
          if rs2 < 1.5e-28
            cgdone = 1
          else
            bb = rs2 / rs
            i = 0
            while i < nw
              d[i] = r[i] + bb * d[i]
              i += 1
            end
            rs = rs2
          end
          cg += 1
        end
        # ---- damped step: full Newton step unless it does not descend -----
        tstep = 1.0
        ls = 0
        lsdone = 0
        while ls < 8 && lsdone == 0
          i = 0
          while i < nw
            y[i] = w[i] + tstep * p[i]
            i += 1
          end
          fy = grad_loss(data, nd, y, gs, nw)
          if fy < f
            i = 0
            while i < nw
              w[i] = y[i]
              i += 1
            end
            lsdone = 1
          else
            # / 2.0, not * 0.5 (bit-identical for binary floats): vendor
            # inference types a LOOP-CARRIED `x = x * <float>` as Integer and
            # the generator loudly refuses it, while `x = x / 2.0` and
            # `x = x + <float>` infer Float (measured -- reject corpus n4/n5).
            tstep = tstep / 2.0
          end
          ls += 1
        end
        stepped += 1
        it += 1
      else
        it = iters
      end
    end
    stepped
  else
    -1
  end
end

# ---- F. the length-check probe for the NEW extern (D-10 runtime half) -----
# The same three-armed probe E083 ran against the grad extern, against the
# hvp extern: extra=0 is the control (returns grad f . dir through the
# forward-over-reverse boundary), extra=1 and extra=-(nw+1) must be trap
# code 4 BEFORE the call.
freestanding_def :hvp_probe,
                 params: [[:f64_buf, :in], :len, [:f64_buf, :inout],
                          [:f64_buf, :inout], [:f64_buf, :inout],
                          [:f64_buf, :inout], :len, :i32],
                 returns: :f64
def hvp_probe(data, nd, w, dir, g, hv, nw, extra)
  hvp_loss(data, nd, w, dir, g, hv, nw + extra)
end
