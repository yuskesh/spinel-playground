# A SMALLER length than the buffers were declared with is legal at compile
# time and checked at run time (0 <= n <= declared len) -- partial batches are
# a real use, and the check is about licensing MORE than was handed over.
require_relative "spinel/freestanding"
freestanding_def :go, params: [[:f64_buf, :in], :len, [:f64_buf, :inout], [:f64_buf, :inout], :len], returns: :f64
def go(d, nd, w, g, nw)
  grad_loss(d, nd, w, g, 3)
end
