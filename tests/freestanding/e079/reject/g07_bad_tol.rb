require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a8: a non-positive G3 threshold is a gate that cannot fail.
freestanding_grad_def :losst, wrt: :w, tol: 0.0
freestanding_def :losst, params: [[:f64_buf, :in], :len], returns: :f64
def losst(w, nw)
  w[0] * w[0]
end
