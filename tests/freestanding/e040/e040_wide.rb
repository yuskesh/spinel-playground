# spinel: int64
# E040 kernel file, the i64 boundaries -- moved out of e040_kern.rb when a
# 32-bit target stopped accepting a 64-bit body (decision 0019, revised
# 2026-10-21). run_wide.sh builds it for the 64-bit host only.
require_relative "spinel/freestanding"

# i64 return with i32 arguments: the product of two i32 CANNOT overflow the i64
# body, so nothing here can trap -- the widths make the check unnecessary and
# the generator emits none.  This is decision D-1 case C paying for itself.
freestanding_def :mulwide, params: [:i32, :i32], returns: :i64
def mulwide(a, b)
  a * b
end

# An i64 boundary on BOTH sides, so that the i64 body itself can be made to
# overflow: this is the only way to reach trap code 1 (as opposed to code 3,
# which is the boundary refusing a value that does not fit).
freestanding_def :bigmul, params: [:i64, :i64], returns: :i64
def bigmul(a, b)
  a * b
end
