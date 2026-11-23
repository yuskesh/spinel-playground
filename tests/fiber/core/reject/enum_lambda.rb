# The yielder used inside a lambda in the body: refused by the rewrite,
# not left for the Spinel build to find.
require "spinel/core"
state :out, :i32, 1
enum_def :evens, max: 1
every_ms 10, :tick

def evens(y, n)
  f = ->(v) { y << v }
  f.call(n)
end

def tick(out)
  Evens.start(0, 3) unless Evens.alive?(0)
  out[0] = Evens.next(0)
  0
end
