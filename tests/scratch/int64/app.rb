# spinel: int64
# Decision 0041 stage 2, the review: a 64-bit body (decision 0019) has
# 8-byte words and elements. Its 32-byte region holds the word and 3 of
# them, and 2^40 fits one, so a release runs with status 0. The suite lists
# this file in a table of its own; under this tree's table, which does not
# list it, run-host refuses it by name, as the build does.
require "spinel/core"
state :out, :i64, 1
scratch 32
every_ms 10, :tick

def tick(out)
  a = Core::Buffer.i64(1, 1099511627776)
  out[0] = a[0]
  0
end
