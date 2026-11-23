# A helper walks a buffer lent from an :out buffer.
require_relative "spinel/freestanding"
def total(b)
  s = 0
  b.each do |v|
    s += v
  end
  s
end
freestanding_def :k, params: [[:i32_buf, :out], :len], returns: :i32
def k(out, n)
  total(out)
end
