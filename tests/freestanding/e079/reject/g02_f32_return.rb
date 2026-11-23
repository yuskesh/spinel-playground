require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a2: the loss is declared :f32, so the value differentiated is a ROUNDED
# one (E077 D-4) -- the gradient would belong to a different function.
freestanding_grad_def :lossf, wrt: :w
freestanding_def :lossf, params: [[:f64_buf, :in], :len], returns: :f32
def lossf(w, nw)
  w[0] * w[0] + w[1] * w[1]
end
