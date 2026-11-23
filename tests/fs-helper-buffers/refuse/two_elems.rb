# One helper parameter lent an :f32 buffer at one call and an :f64 at another.
require_relative "spinel/freestanding"
def half(b, i)
  b[i] = 0.5
  0
end
freestanding_def :k, params: [[:f32_buf, :inout], :len, [:f64_buf, :inout], :len],
                     returns: :i32
def k(a, na, b, nb)
  half(a, 0)
  half(b, 0)
end
