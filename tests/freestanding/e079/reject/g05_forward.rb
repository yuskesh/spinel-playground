require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a6: forward mode is P007 Phase 4 -- refused, not silently made reverse.
freestanding_grad_def :lossfw, wrt: :w, mode: :forward
freestanding_def :lossfw, params: [[:f64_buf, :in], :len], returns: :f64
def lossfw(w, nw)
  w[0] * w[0]
end
