# A helper reads, through a relay, a buffer lent from an :out buffer.
require_relative "spinel/freestanding"
def peek(b)
  b[0]
end
def relay(b)
  peek(b)
end
freestanding_def :k, params: [[:i32_buf, :out], :len], returns: :i32
def k(out, n)
  relay(out)
end
