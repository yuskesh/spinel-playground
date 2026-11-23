require_relative "spinel/freestanding"
freestanding_def :go, params: [[:u8_buf, :in], :len, [:f64_buf, :inout], [:f64_buf, :inout], :len], returns: :f64
def go(d, nd, w, g, nw)
  grad_loss(d, nd, w, g, nw)
end
