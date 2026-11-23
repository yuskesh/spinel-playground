# A helper takes a view of its lent buffer (E083's profile).
require_relative "spinel/freestanding"
def loss(w, x, g, n)
  grad_loss(w[0, 1], 1, x, g, n)
end
freestanding_def :k, params: [[:f64_buf, :in], [:f64_buf, :in], [:f64_buf, :out], :len],
                     returns: :f64
def k(w, x, g, n)
  loss(w, x, g, n)
end
