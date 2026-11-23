require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a5: wrt: names something that is not a parameter at all.
freestanding_grad_def :lossu, wrt: :theta
freestanding_def :lossu, params: [[:f64_buf, :in], :len], returns: :f64
def lossu(w, nw)
  w[0] * w[0]
end
