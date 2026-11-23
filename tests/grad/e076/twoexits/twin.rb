# E076 -- the lane-entrance measurement (docs/overview.md s7, ground (iii)).
#
# The claim `tools/grad` enters on is TWO EXITS FROM ONE EMISSION: `spinel -c`
# runs once, and the bytes it produces feed both the program's own function and
# the function's adjoint.  This file exists so that claim is a measurement.
#
# `twin` (twin_kernel.rb, textually required here) is called TWICE:
#   * as an ordinary Ruby method -- spinel emitted it into THIS binary;
#   * through `gdval_twin`, which is `spg_val_twin` inside the object file
#     gradgen built, out of a single `spinel -S`, alongside the adjoint.
#
# One source text, two builds, one of which went through the pin, the GC-root
# elision pass and Enzyme.  If the values ever disagree, that pipeline changed
# the function, and every gradient it produces is a gradient of something else.
# The comparison below is on the raw bits, not on a printed decimal.
require_relative "twin_kernel"
require_relative "twin_grad.gen"

grad_check_signatures!

# 25 points, spread over three decades, including negatives.
same = 0
diff = 0
worst = 0.0
i = 0
while i < 25
  a = 0.5 + i.to_f * 0.37
  b = -2.0 + i.to_f * 0.19
  c = 0.125 * (i % 7).to_f - 0.5
  x = twin(a, b, c)             # exit 1: this binary's own copy
  y = gdval_twin(a, b, c)       # exit 2: the adjoint object's copy
  if x == y
    same += 1
  else
    diff += 1
    d = (x - y).abs
    worst = d if d > worst
  end
  i += 1
end
puts "points\t25"
puts "bitwise_equal\t#{same}"
puts "differing\t#{diff}"
puts "worst_abs_diff\t#{worst}"

# And the gradient of the same body, from the same object.
da = Array.new(1, 0.0)
db = Array.new(1, 0.0)
v = grad_twin(2.0, -0.5, 0.25, da, db)
puts "twin(2,-0.5,0.25)\t#{v}"
puts "d/da\t#{da[0]}"
puts "d/db\t#{db[0]}"
