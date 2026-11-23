# examples/image/resize -- the kernel side.
#
# This file is **not run**. It is declarations that `spinel-mlirgen --tensor`
# reads and turns into MLIR, not something the program requires.
#
# Origin: the two `tp_*` declarations (route (b), banded matrices) of
# docs/experiments/results/E072/e072_kernels.rb. Not one byte of their text
# changed, so E072's measurements that the README cites
# (results/E072/uhd.tsv) are this example's expected values as they are.
#
# The difference from a window op (`conv2d`) is the subject of this example.
#
# The window ops put their coefficients in the **declaration**. That is a good
# rule and buys three things: the coefficients enter the signature hash,
# whether they are dyadic is known at compile time, and the caller need not
# transfer a coefficient tensor. The price is a static channel count.
#
# **That rule cannot write bilinear weights.** A weight is
#
#     s = (j + 0.5) * (n_in / n_out) - 0.5
#
# and neither n_in nor n_out exists until the program runs. So the design had
# to decide where that arithmetic is done. The answer: coefficients that depend
# on the run-time shape are **tensor arguments**, built by the host in f64 and
# rounded to f32 once, on upload. The reason is numerical, not convenience:
# written inside the kernel, the same expression needs an `arith.divf` of two
# run-time dimensions, which Metal does not round correctly. E072 measured it
# (only the `bilinear` route, which makes its coordinates inside the kernel,
# differs between devices).
#
# And the coefficients are held **banded**. The bilinear weight matrix is
# n_in x n_out with only two non-zeros per column. A dense contraction does
# O(N·sqrt(N)) work for an O(N) answer: 1.7e10 multiply-adds against 8e6 for
# 4K to 1080p. `tap_mul` takes K tap **positions** `idx` and K **weights**
# `wgt` as (n_out, K). K is a run-time dimension, so the same entry serves
# bilinear (K=2), bicubic (K=4) and Lanczos-3 (K=6). The dense `mode_mul` is
# still on the surface (a general linear map needs it), but **at 4K it is 763
# times slower**.
#
# This file has no `windows:`, `channels:` or `border:`. That is the visible
# side of the same finding: an op with no declared coefficients has no static
# shape to keep, so the channel axis stays dynamic, and **one entry of one
# .vmfb resamples both a 1-channel PGM and a 3-channel PPM**.
require_relative "spinel/tensor"

# ---- stage 1: contract axis 0 (rows). u8 in, f32 out -------------------------
# The u8 -> f32 widening happens **inside** the contraction's region: two more
# integer operations per multiply-add, and no extra dispatch or f32 copy of the
# image.
tensor_def :tap_y_f32, dtype: :f32, dtypes: [:u8, :f32, :f32, :f32],
           params: [:ten3, :mat, :mat, :ten3], dest: 3
def tap_y_f32(src, iy, wy, dst)
  dst.assign(src.tap_mul(:d0, iy, wy))
end

# ---- stage 2: contract axis 1 (columns) and quantise on the way out ----------
# The destination is :u8, so the quantising epilogue (roundeven + clamp +
# fptoui) is inserted automatically. The rounding stays `quant:`'s default,
# half-to-even. As measured, **this is the only difference from a pure Ruby
# loop**.
tensor_def :tap_x_u8, dtype: :f32, dtypes: [:f32, :f32, :f32, :u8],
           params: [:ten3, :mat, :mat, :ten3], dest: 3
def tap_x_u8(src, ix, wx, dst)
  dst.assign(src.tap_mul(:d1, ix, wx))
end
