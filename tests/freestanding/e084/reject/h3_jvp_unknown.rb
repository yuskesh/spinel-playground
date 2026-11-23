# h3: jvp: on freestanding_grad_def -- gradfs has no jvp product (the pure
# forward directional derivative is host-only, E082), and an unknown keyword
# is refused loudly rather than ignored.
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
freestanding_grad_def :one, wrt: :a, jvp: true
freestanding_def :one, params: [[:f64_buf, :in], :len], returns: :f64
def one(a, na)
  a[0] * a[0]
end
