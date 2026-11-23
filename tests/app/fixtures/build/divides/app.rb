# spinel: int64
# The 64-bit division control of the plan's D3 item (Task 11): one thread
# entry whose i64 arithmetic divides a running value by a small divisor
# every release, so a verification run's SPC_CYCLES figures show the
# __aeabi_ldivmod calls and their share of the invocation's instructions,
# which the acceptance sample (no 64-bit division) cannot show. No board
# member and no channel: the transport thread only drains the trace.
require "spinel/core"
state :acc, :i64, 1
state :n, :u32, 1
every_ms 2, :step
def step(acc, n)
  acc[0] = (acc[0] * 1000003 + 7) / (3 + (n[0] & 1))
  n[0] = n[0] + 1
  0
end
