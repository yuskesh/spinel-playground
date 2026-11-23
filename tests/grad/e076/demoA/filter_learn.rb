# E076 demo A -- the differentiable half of "learn a filter from examples".
#
# THE SHAPE OF THE DEMO.  P002's window coefficients are DECLARED (R004 W2):
# `windows: { g: [[1,2,1],[2,4,2],[1,2,1]] }, window_scale: 0.0625`.  This file
# asks the opposite question -- given an input image and the output somebody
# wants, what were the coefficients? -- and answers it with the gradient the
# compiler synthesises from THIS ordinary Ruby method.
#
# The window is written SEPARABLY (a 3-tap vertical pass composed with a 3-tap
# horizontal pass) for one reason: that is the shape the tensor surface's
# RUNTIME-COEFFICIENT entry takes.  `tap_mul(:d0|:d1, idx, wgt)` (R004 W6,
# E072) receives (n_out, K) index and weight matrices from the host, so the
# coefficients this file learns can be handed to the GPU without changing a
# single declaration.  A full 3x3 window would have had to go back into a
# `windows:` declaration, which is a recompile, not a run-time value.
#
# The 1/16 gaussian IS separable -- [1,2,1]/4 outer [1,2,1]/4 -- so the known
# answer is inside the model class, and "did it recover the coefficients" is a
# question with a number for an answer.
#
# BORDER.  Replicate (indices clamped), because that is what a host builds when
# it fills `idx` for `tap_mul`: the tensor entry has no `border:` of its own,
# the clamping lives in the index matrix.  The reference below and the GPU pass
# therefore agree by construction rather than by luck.
require_relative "spinel/grad"

# The loss: squared error between "src filtered by the separable window
# (ky outer kx)" and the wanted output `tgt`.  Everything is Array[Float] and
# every local is Float or Integer -- no boxing, no allocation, no constants.
# That is not a coincidence, it is the differentiable subset (R013 s3.3).
grad_def :blur_loss, wrt: [:ky, :kx], tol: 1.0e-6,
         probe: [[[0.30, 0.40, 0.30], [0.30, 0.40, 0.30],
                  [0.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 255.0,
                   12.0, 200.0, 7.0, 60.0, 33.0, 140.0, 90.0],
                  [10.0, 30.0, 62.0, 94.0, 126.0, 158.0, 190.0, 222.0, 250.0,
                   14.0, 198.0, 9.0, 58.0, 35.0, 138.0, 92.0],
                  4.0, 4.0],
                 [[0.25, 0.50, 0.25], [0.10, 0.80, 0.10],
                  [3.0, 9.0, 27.0, 81.0, 243.0, 1.0, 5.0, 25.0, 125.0,
                   2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0],
                  [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                   0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                  4.0, 4.0]]
def blur_loss(ky, kx, src, tgt, h, w)
  loss = 0.0
  y = 0
  while y < h
    x = 0
    while x < w
      acc = 0.0
      j = 0
      while j < 3
        yy = y + j - 1
        yy = 0 if yy < 0
        yy = h - 1 if yy > h - 1
        row = 0.0
        i = 0
        while i < 3
          xx = x + i - 1
          xx = 0 if xx < 0
          xx = w - 1 if xx > w - 1
          row += kx[i] * src[yy * w + xx]
          i += 1
        end
        acc += ky[j] * row
        j += 1
      end
      d = acc - tgt[y * w + x]
      loss += d * d
      x += 1
    end
    y += 1
  end
  loss
end

# The file runs.  `grad_def` is a declaration, not a dialect: this is an
# ordinary Spinel program and `blur_loss` is an ordinary Ruby method.
s = [0.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 255.0,
     12.0, 200.0, 7.0, 60.0, 33.0, 140.0, 90.0]
t = [10.0, 30.0, 62.0, 94.0, 126.0, 158.0, 190.0, 222.0, 250.0,
     14.0, 198.0, 9.0, 58.0, 35.0, 138.0, 92.0]
puts blur_loss([0.25, 0.5, 0.25], [0.25, 0.5, 0.25], s, t, 4, 4)
