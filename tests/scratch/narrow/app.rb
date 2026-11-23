# Decision 0041 stage 2: int64's 32-bit twin. The body is 32 bits, so the
# array's element is an i32, and storing 2^40 in it is ARITHMETIC (status 2)
# at release 1 on the host.
require "spinel/core"
state :out, :i64, 1
scratch 32
every_ms 10, :tick

def tick(out)
  a = Core::Buffer.i32(1, 1099511627776)
  out[0] = a[0]
  0
end
