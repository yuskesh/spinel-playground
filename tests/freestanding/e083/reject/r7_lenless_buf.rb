require_relative "spinel/freestanding"
freestanding_def :go, params: [[:f64_buf, :in], :i32, [:f64_buf, :inout], [:f64_buf, :inout], :len], returns: :f64, bounds: :unchecked
def go(d, nd, w, g, nw)
  grad_loss(d, nd, w, g, nw)
end
