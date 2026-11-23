# n3: a block. In E084 this was refused ("takes a block"), which is WHY every
# loop in the kernel is a `while` (E082's host newton_demo used 20.times /
# 8.times). Decision 0041 stage 1 admits a literal block on `times`, so the
# row is now accepted. The original body's `s += g[i]` is refused on a Float
# accumulator with `while` as well, so the body uses `s = s + g[i]`.
require_relative "spinel/freestanding"
freestanding_def :dots, params: [[:f64_buf, :in], :len], returns: :f64
def dots(g, n)
  s = 0.0
  n.times do |i|
    s = s + g[i]
  end
  s
end
