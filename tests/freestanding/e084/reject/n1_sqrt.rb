# n1: Math.sqrt in the freestanding subset -- WHY the kernel's stopping rule
# is on ||g||^2 (e084_kern.rb sN1).  Constant lookup is a runtime operation.
require_relative "spinel/freestanding"
freestanding_def :gnorm, params: [[:f64_buf, :in], :len], returns: :f64
def gnorm(g, n)
  s = 0.0
  i = 0
  while i < n
    s = s + g[i] * g[i]
    i += 1
  end
  Math.sqrt(s)
end
