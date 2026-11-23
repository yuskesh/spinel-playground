# h2: hvp: with a non-boolean value -- refused at the declaration reader,
# not silently truthy.
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
freestanding_grad_def :one, wrt: :a, hvp: 1
freestanding_def :one, params: [[:f64_buf, :in], :len], returns: :f64
def one(a, na)
  a[0] * a[0]
end
