# An :out buffer, lent on by a helper, reaches an entry callee that reads it.
require_relative "spinel/freestanding"
freestanding_def :g, params: [[:i32_buf, :in], :len], returns: :i32
def g(b, n)
  b[0]
end
def pass(b, n)
  g(b, n)
end
freestanding_def :k, params: [[:i32_buf, :out], :len], returns: :i32
def k(out, n)
  pass(out, n)
end
