require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a4: wrt: an f32 buffer.  The shadow would round on the way out.
freestanding_grad_def :loss32, wrt: :w
freestanding_def :loss32, params: [[:f32_buf, :in], :len], returns: :f64
def loss32(w, nw)
  w[0] * w[0] + w[1] * w[1]
end
