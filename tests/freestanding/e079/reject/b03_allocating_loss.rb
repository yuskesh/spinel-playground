require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# b3: a loss that keeps a per-row array.  Heap, therefore GC, therefore not
# freestanding -- and therefore not differentiable here either (R013 O5).
freestanding_grad_def :lossa, wrt: :w
freestanding_def :lossa, params: [[:f64_buf, :in], :len], returns: :f64
def lossa(w, nw)
  t = [w[0], w[1]]
  t[0] * t[0]
end
