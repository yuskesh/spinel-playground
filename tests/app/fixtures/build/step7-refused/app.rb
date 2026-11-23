# The step 7 control of Task 10: an entry the kernel refuses under realtime
# (a loop with no derived bound, the shape of tests/app/fixtures/apps/
# net-unbounded). Steps 1 to 6 pass; step 7 fails; no firmware is left.
require "spinel/core"
state :frame, :u8, 24
state :value, :i32, 1
every_ms 5, :report
def put_dec_unbounded(out, pos, v)
  digits = 0
  while v != 0
    out[pos + digits] = 48 + v % 10
    v = v / 10
    digits += 1
  end
  pos + digits
end
def report(frame, value)
  put_dec_unbounded(frame, 0, value[0])
  0
end
