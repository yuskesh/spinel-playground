# examples/tensor/fusion -- the kernel world.
#
# These are the declarations of **the side that is not fused**: `y = x*a + y` split one op
# per tensor_def, the comparison for the fused statement `y.assign!(x * a + y)`.
#
# Origin: k_mul / k_addto of the predecessor's measured kernels (e038_kernels.rb).
# The operand order of each link matches the order the fusion emitter gives the same
# subexpression, so the two forms **differ in nothing but where the dispatch boundary is**.
require_relative "spinel/tensor"

# t = x * a
tensor_def :k_mul, dtype: :f32, params: [:scalar, :vec, :vec], dest: 2
def k_mul(a, x, t)
  t.assign(x * a)
end

# y = t + y
tensor_def :k_addto, dtype: :f32, params: [:vec, :vec], dest: 1
def k_addto(t, y)
  y.assign(t + y)
end
