# hc1 (control): hvp: false is exactly the pre-E084 declaration -- one
# gradient export, no hvp symbol.
require_relative "spinel/freestanding"
require_relative "spinel/grad_freestanding"
freestanding_grad_def :one, wrt: :a, hvp: false
freestanding_def :one, params: [[:f64_buf, :in], :len], returns: :f64
def one(a, na)
  a[0] * a[0]
end
