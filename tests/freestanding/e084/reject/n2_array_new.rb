# n2: a local scratch vector -- WHY newton_calibrate's boundary carries eight
# caller-owned buffers.  There is no heap to allocate p/r/d/y from.
require_relative "spinel/freestanding"
freestanding_def :cgstep, params: [[:f64_buf, :in], :len], returns: :f64
def cgstep(g, n)
  p = Array.new(n, 0.0)
  p[0] = g[0]
  p[0]
end
