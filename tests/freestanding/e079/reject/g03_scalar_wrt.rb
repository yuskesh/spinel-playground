require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a3: wrt: a SCALAR.  Reverse mode returns an active scalar derivative
# through the call, which would change the boundary signature.
freestanding_grad_def :lossx, wrt: :x
freestanding_def :lossx, params: [:f64, [:f64_buf, :in], :len], returns: :f64
def lossx(x, w, nw)
  x * w[0] + x * x
end
