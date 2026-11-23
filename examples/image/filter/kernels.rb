# examples/image/filter -- the kernel world.
#
# This file is **never run**. It is declarations that `spinel-mlirgen --tensor` reads and
# turns into MLIR, not something the program requires
# ("Two worlds" in tools/tensor/README.md). What the program reads is
# kernels.gen.rb, generated from here.
#
# Origin: the s3 family (plain 3 stages) of the predecessor's measured kernels.
# Not one byte of the spelling was changed, so the measurements the README cites
# are this sample's expected values as they are.
#
#     u8 image --> blur (3x3 gaussian) --> sobel L1 --> tail --> u8 image
#
# **3 stages are 3 declarations and 3 invokes.** No intermediate (f32) byte returns to the host.
# The same pipeline was also written and measured as 2 declarations (folding the tail) and
# 1 declaration (composing the 2 stencils into one 5x5 by convolution algebra), but that
# experiment's handover was **write the exhibit as s3**: the composed version is faster on
# Metal but changes the boundary semantics by a 1-pixel frame, and is slower on the CPU.
#
# The gradient being L1 (|gx| + |gy|) is a design decision, not a shortcut. The textbook
# sobel is sqrt(gx^2 + gy^2), but Metal's `sqrt` was measured at up to 2 ulp, `** 0.5`
# was hoped to be a way out, and a later measurement closed that door
# (powf with exponent 0.5 is the same operation as sqrt, bit for bit). Where it leaks was
# measured too: on an unsaturated sobel the 2 ulp reach the bytes, and **100% of the pixels
# that moved sat on a rounding boundary**. A pipeline whose goal is "the same bytes on both
# devices" cannot be built on an op known to break it.
# `abs` is exact in every rounding mode.
#
# The windows being dyadic is deliberate too. With a 1/16 gaussian and integer sobel taps,
# every partial sum is an integer multiple of 2^-4 and stays inside f32's exact-integer range.
# So **the convolution is exact**, and the order of the sums cannot change the answer. That
# is why "bitwise equal on both devices, on 3 devices" can be "the same", not
# "close".
require_relative "spinel/tensor"

# ============================================================ stage 1: blur
# u8 in, f32 out. The generator inserts the u8->f32 at the entrance on its own, from the
# declaration's `dtypes:`. `pad_via: :auto` chooses the boundary's lowering by the device
# compiled for. The 2 lowerings are pixel-identical, so the choice is **a decision about
# speed, not about semantics** (measured in both directions).
tensor_def :blur_f32, dtype: :f32, dtypes: [:u8, :f32],
           params: [:ten3, :ten3], dest: 1,
           channels: 1, border: :zero, pad_via: :auto,
           windows: { g: [[1.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 2.0, 1.0]] },
           window_scale: 0.0625
def blur_f32(src, dst)
  dst.assign(src.conv2d(:g))
end

# ==================================================== stage 2: sobel L1 (f32)
# f32 in, f32 out. Not one byte appears in the middle of the pipeline:
# that is what residency means.
tensor_def :sobel_f32, dtype: :f32, dtypes: [:f32, :f32],
           params: [:ten3, :ten3], dest: 1,
           channels: 1, border: :zero, pad_via: :auto,
           windows: { gx: [[-1.0, 0.0, 1.0], [-2.0, 0.0, 2.0], [-1.0, 0.0, 1.0]],
                      gy: [[-1.0, -2.0, -1.0], [0.0, 0.0, 0.0], [1.0, 2.0, 1.0]] }
def sobel_f32(src, dst)
  dst.assign(src.conv2d(:gx).abs + src.conv2d(:gy).abs)
end

# ==================================================== stage 3: tail (2 kinds)
# Both are **pointwise operations** on an f32 tensor, and the destination is :u8, so the
# quantization epilogue (roundeven + clamp + fptoui) makes the bytes.
#
# There are two because the goal sentence asks for both:
#
#   `thresh_u8` is the wording itself (blur -> sobel -> threshold). Its output is 0 or 255,
#     and it **does not test the quantizer at all**; instead the tie question moves to the threshold's boundary.
#   `gain_u8`   is the tail that tests the quantizer. Its output takes 256 values and lands on
#     rounding boundaries, so there is something to count for "rounded to u8".
#
# As an exhibit, either one alone is not enough. One meets the wording; the other
# makes "rounded" checkable.
tensor_def :thresh_u8, dtype: :f32, dtypes: [:f32, :f32, :u8],
           params: [:scalar, :ten3, :ten3], dest: 2
def thresh_u8(t, src, dst)
  dst.assign(src.ge(t) * 255.0)
end

tensor_def :gain_u8, dtype: :f32, dtypes: [:f32, :f32, :u8],
           params: [:scalar, :ten3, :ten3], dest: 2
def gain_u8(g, src, dst)
  dst.assign(src * g)
end
