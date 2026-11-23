require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a9: two gradients of one method.
freestanding_grad_def :lossd, wrt: :w
freestanding_grad_def :lossd, wrt: :w, tol: 1.0e-3
freestanding_def :lossd, params: [[:f64_buf, :in], :len], returns: :f64
def lossd(w, nw)
  w[0] * w[0]
end
