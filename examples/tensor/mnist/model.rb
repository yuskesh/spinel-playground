# examples/tensor/mnist -- these 2 declarations are **the whole model** on the Ruby side.
#
# Where `tensor_def` "generates MLIR from a declaration", `tensor_extern` puts an
# **entry it does not generate** (a function inside a `.vmfb` made elsewhere) under the
# same table, the same shim and the same refusal discipline. What is named here is a module
# made by running `iree-compile` on the StableHLO that JAX wrote with `jax.export`;
# it was trained by the predecessor's experiment (train_export.py, test accuracy 98.11%).
#
# Origin: :mnist_mlp and :mnist_scale of the predecessor's experiment model (e037_model.rb).
# The spelling is unchanged (:mnist_mlp's signature hash has not changed since it was trained).
require_relative "spinel/tensor"

# ---- preprocessing: i8[b,784] pixels to f32[b,784] --------------------------------
# The first version did this in a Ruby while loop: 39.8 ms for 10 000 images,
# longer than the inference itself. It was then **moved to the model's side** and
# loaded into the same session as a second module (0.79 ms).
#
# The input is **signed** i8 because iree-compile 3.11.0 refuses `tensor<?x784xui8>`;
# the graph turns it back into 0..255 (exactly).
tensor_extern :mnist_scale, dtype: :f32, dtypes: [:i8],
              vm_module: :jit_scale_only, entry: :main,
              params: [:mat], shapes: [[:batch, 784]],
              returns: :mat, returns_shape: [:batch, 784]

# ---- a 784-128-10 MLP. f32[b,784] -> f32[b,10] logits -------------------------------
# `returns:` is the essential difference from tensor_def. A generated kernel is
# destination-passing, with every tensor an argument, but the exported model is
# `main(x) -> y` and **returns its result**. Ruby calls it the same way; the last Tensor
# takes over the buffer view that comes back.
tensor_extern :mnist_mlp, dtype: :f32,
              vm_module: :jit_infer, entry: :main,
              params: [:mat], shapes: [[:batch, 784]],
              returns: :mat, returns_shape: [:batch, 10]
