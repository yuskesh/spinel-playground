require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"

# b4: THE MEASUREMENT BEHIND E079 s3.  The obvious thing to write is the whole
# calibration as one freestanding entry -- forty steps, no driver at all.  It
# needs to call the adjoint, and the adjoint is not a Ruby method: it is a
# symbol Enzyme synthesises at the LLVM level.  A freestanding kernel cannot
# call a symbol it did not define until P003 Phase 4 (platform externs).
freestanding_def :calibrate, params: [[:f64_buf, :inout], [:f64_buf, :out],
                                      [:f64_buf, :in], :len, :i32, :f64],
                 returns: :i32
def calibrate(w, g, data, n, steps, lr)
  t = 0
  while t < steps
    spinel_grad_sq_hinge_loss(data, n, w, g, 5)
    i = 0
    while i < 5
      w[i] = w[i] - lr * g[i]
      i += 1
    end
    t += 1
  end
  steps
end
