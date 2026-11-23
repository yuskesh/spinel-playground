# E076 demo B -- the differentiable half of "calibrate a scorer from labels".
#
# THE SHAPE OF THE DEMO.  examples/gatekeeper's `bot_score` (E066) is an
# INTEGER kernel: ten predicates over request features, each worth a
# hand-chosen number of points, summed and clamped to 0..100.  It runs on every
# request, in a ~2 KB wasm module with no heap, and its arithmetic is the same
# everywhere forever -- that is the whole design and none of it is being
# changed here.  R013 s3.3 O2 is also very clear that it CANNOT be
# differentiated: an integer primal gets an empty adjoint and no diagnostic.
#
# So the calibration is a TWO-PHASE construction, exactly the one P007 Phase 1
# asks for:
#
#   phase 1 (this file, f64)   a twin of the same linear form, over the same
#                              ten predicates, learned from labelled data with
#                              the gradient Enzyme synthesises;
#   phase 2 (calib.rb)         the settled weights are rounded to integers and
#                              baked back into the gatekeeper's kernel shape,
#                              and the DECISION QUALITY is measured before and
#                              after.
#
# WHY PAIRWISE.  The thing that actually matters is the verdict
# `score >= threshold`, and a threshold is a step: its derivative is 0 almost
# everywhere and undefined on the boundary, so no gradient method can see it.
# A pairwise loss moves the question to "is this bot scored above this human",
# which is a difference of scores and is perfectly smooth.  The threshold is
# then chosen afterwards, by sweeping it -- which is what a deployment does
# anyway (`bot_block` takes the threshold as an argument precisely so that
# tuning it is a deployment change and not a recompile).
#
# The regulariser is not decoration either.  softplus(-m) keeps falling as the
# whole weight vector is scaled up, so without a penalty the descent inflates
# the scale forever and never settles on numbers to round.  lam fixes the
# gauge; the integerisation in phase 2 then has something definite to quantise.
require_relative "spinel/grad"

# fb / fh: two npair x nf matrices, row-major.  Row p of fb is the feature
# vector of a bot, row p of fh of a human it is paired with.  Features are
# 0.0/1.0 indicators -- the SAME ten predicates the integer kernel tests.
grad_def :rank_loss, wrt: [:w], tol: 1.0e-6,
         probe: [[[0.5, -0.25, 2.0],
                  [1.0, 0.0, 1.0,  0.0, 1.0, 0.0],
                  [0.0, 1.0, 0.0,  1.0, 1.0, 1.0],
                  2.0, 3.0, 0.01],
                 [[3.0, 3.0, 3.0],
                  [1.0, 1.0, 1.0,  1.0, 0.0, 1.0],
                  [0.0, 0.0, 0.0,  0.0, 1.0, 0.0],
                  2.0, 3.0, 0.25]]
def rank_loss(w, fb, fh, npair, nf, lam)
  loss = 0.0
  p = 0
  while p < npair
    m = 0.0
    j = 0
    while j < nf
      m += w[j] * (fb[p * nf + j] - fh[p * nf + j])
      j += 1
    end
    # softplus(-m), written in the two arms that keep exp() in range.  The two
    # arms are the SAME analytic function, so there is no kink here for the
    # finite-difference gate to trip over -- unlike relu (R013 s3.3), where
    # the arms genuinely differ and G3's oracle stops being valid at x=0.
    if m > 0.0
      loss += Math.log(1.0 + Math.exp(0.0 - m))
    else
      loss += (0.0 - m) + Math.log(1.0 + Math.exp(m))
    end
    p += 1
  end
  reg = 0.0
  j = 0
  while j < nf
    reg += w[j] * w[j]
    j += 1
  end
  loss + lam * reg
end

# The file runs: `grad_def` is a declaration, and this is an ordinary program.
w = [0.5, -0.25, 2.0]
fb = [1.0, 0.0, 1.0, 0.0, 1.0, 0.0]
fh = [0.0, 1.0, 0.0, 1.0, 1.0, 1.0]
puts rank_loss(w, fb, fh, 2, 3, 0.01)
