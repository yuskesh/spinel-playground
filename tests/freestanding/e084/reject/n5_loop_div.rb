# n5: the ACCEPTED pair of n4 -- same loop, halving by division.  For binary
# floats x/2.0 == x*0.5 bit for bit, so the workaround costs nothing; the
# asymmetry itself is the record (vendor inference, not a semantics choice).
require_relative "spinel/freestanding"
freestanding_def :halve, params: [[:f64_buf, :inout], :len, :i32], returns: :i32
def halve(w, nw, iters)
  it = 0
  x = 1.0
  while it < iters
    x = x / 2.0
    it += 1
  end
  w[0] = x
  0
end
