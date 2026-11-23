require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
# a1: a gradient of something that has no freestanding_def boundary.
freestanding_grad_def :orphan, wrt: :w
def orphan(w, nw)
  w[0] * w[0]
end
