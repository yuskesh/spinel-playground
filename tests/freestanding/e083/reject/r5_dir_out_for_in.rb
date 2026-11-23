require_relative "spinel/freestanding"
freestanding_def :go, params: [[:f64_buf, :in], :len, [:f64_buf, :out], [:f64_buf, :out], :len], returns: :f64
def go(d, nd, w, g, nw)
  grad_loss(d, nd, w, g, nw)
end
