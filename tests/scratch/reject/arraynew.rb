# Decision 0045: the Array spelling of a scratch array is refused by name,
# with the Core::Buffer it is written as.
require "spinel/core"
state :out, :i32, 1
scratch 64
every_ms 10, :tick

def work(n)
  a = Array.new(n, 2)
  a[0] + a.size
end

def tick(out)
  out[0] = work(2)
  0
end
