require_relative "spinel/freestanding"

# b5: the second half of the same measurement.  Even if the adjoint WERE a
# Ruby method, the loop still could not be written: E077's boundary pairs a
# buffer with its `:len` in the DECLARATION, and that pairing does not travel
# across an internal call.  So `calibrate` cannot hand `data` to a private
# helper either.  Both halves have to move for the loop to come in from the
# driver -- see E079's "what goes to phase 4".
#
# Decision 0044 (2026-11-14) lifts the second half: a helper now takes the
# buffers its caller lends it, each as the address and the length the caller
# holds. This file is admitted since then, and run_reject.sh expects ACCEPT.
freestanding_def :calibrate2, params: [[:f64_buf, :inout], [:f64_buf, :in], :len, :f64],
                 returns: :i32
def calibrate2(w, data, n, lr)
  t = 0
  while t < 4
    one_step(w, data, n, lr)
    t += 1
  end
  t
end

def one_step(w, data, n, lr)
  w[0] = w[0] - lr * data[0]
  n
end
