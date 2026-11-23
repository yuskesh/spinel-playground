# A helper passes its lent buffers to a platform extern (E083's profile).
require_relative "spinel/freestanding"
def loss(w, x, g, n)
  grad_loss(w, n, x, g, n)
end
freestanding_def :k, params: [[:f64_buf, :in], [:f64_buf, :in], [:f64_buf, :out], :len],
                     returns: :f64
def k(w, x, g, n)
  loss(w, x, g, n)
end
