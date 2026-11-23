# examples/tensor/dense-relu -- the kernel world.
#
# This file is **never run**. It is declarations that `spinel-mlirgen --tensor` reads and
# turns into MLIR, not something the program requires ("Two worlds" in
# tools/tensor/README.md). What the program reads is kernels.gen.rb, generated from here.
#
# Origin: 3 declarations taken from the predecessor's measured kernels (e033_kernels.rb).
# Not one byte of the spelling was changed, so the measurements the README below cites
# are this sample's expected values as they are.
require_relative "spinel/tensor"

# ---- a dense layer y = relu(W x + b) -------------------------------------------
# matvec + add + relu are **one tensor_def** = 1 dispatch. Splitting the same computation
# into 3 declarations makes 3 dispatches.
tensor_def :dense_relu, dtype: :f32, params: [:mat, :vec, :vec, :vec], dest: 3
def dense_relu(w, b, x, y)
  y.assign((w.matvec(x) + b).relu)
end

# ---- the reduction sum(x*x), the default order of additions --------------------
# The backend may tile / split / vectorize freely. CPU and Metal are **not expected**
# to agree ("The contract on the order of additions" in tools/tensor/README.md).
tensor_def :sumsq, dtype: :f32, params: [:vec], returns: :scalar
def sumsq(x)
  (x * x).sum
end

# ---- the same reduction, in a fixed tree order -----------------------------------
# A tree with fan-out 2. Each output element is one arith.addf, so there is no room to
# reassociate, and the CPU .vmfb and the Metal .vmfb agree **bitwise**.
tensor_def :sumsq_ft, dtype: :f32, params: [:vec], returns: :scalar,
           reduction: :fixed_tree
def sumsq_ft(x)
  (x * x).sum
end
