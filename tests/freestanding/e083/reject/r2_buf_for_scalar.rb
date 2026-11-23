require_relative "spinel/freestanding"
freestanding_def :go, params: [[:f64_buf, :in], :len, [:f64_buf, :inout], [:f64_buf, :inout], :len], returns: :f64
def go(d, nd, w, g, nw)
  grad_loss(d, d, w, g, nw)
end
