# h1: hvp: with two wrt: buffers -- g12 (E082 fwd1 at the freestanding
# boundary: the direction travels along ONE buffer).
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
freestanding_grad_def :two, wrt: [:a, :b], hvp: true
freestanding_def :two, params: [[:f64_buf, :in], :len, [:f64_buf, :in], :len],
                 returns: :f64
def two(a, na, b, nb)
  a[0] * b[0]
end
