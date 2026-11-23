# n4: a LOOP-CARRIED float multiplication -- `x = x * 0.5` inside a while
# loop. The predecessor refused it: whole-program inference typed x as
# Integer under the multiplication's fixpoint seeding, while the bit-identical
# `x = x / 2.0` and the additive `x = x + 0.5` inferred Float (n5 is that
# pair), which is why the kernel's line search halves by DIVISION. Since the
# pin baddd25a9 (upstream bd53f5938, docs/provenance.md) x infers Float and
# the row is an accepted one.
require_relative "spinel/freestanding"
freestanding_def :halve, params: [[:f64_buf, :inout], :len, :i32], returns: :i32
def halve(w, nw, iters)
  it = 0
  x = 1.0
  while it < iters
    x = x * 0.5
    it += 1
  end
  w[0] = x
  0
end
