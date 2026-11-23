# The refused control for spinel/net.rb: a put_dec that loops while the value
# is non-zero has no derived bound, and application rules refuse it as
# loop-unbounded. spinel/net.rb's put_dec bounds the same loop at 20 digits.
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
