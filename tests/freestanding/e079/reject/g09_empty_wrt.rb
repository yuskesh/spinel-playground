require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a10: a gradient with respect to nothing.
freestanding_grad_def :losse, wrt: []
freestanding_def :losse, params: [[:f64_buf, :in], :len], returns: :f64
def losse(w, nw)
  w[0] * w[0]
end
