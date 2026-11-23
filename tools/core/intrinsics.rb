# frozen_string_literal: true
#
# tools/core/intrinsics.rb — the word intrinsics of decisions 0022 and 0042,
# for CRuby.
#
# CORE compiles these names itself (spinel-mlir/Core/Intrinsics.h): a checked
# CORE closure calls them and no definition is looked for. A source that runs
# the same units under CRuby -- the session host, a route that plays the
# units in plain Ruby -- loads this file first, and gets the same answers:
#
#   * every operand must be an Integer in the i32 range (the i64 range for
#     the `w64` and `u64` names), checked before the operation; one outside
#     it raises CoreIntrinsics::Arithmetic, which is what CORE returns as
#     ARITHMETIC;
#   * the comparisons answer true or false;
#   * every other intrinsic answers the low 32 (or 64) bits of its exact
#     result, read as signed; `core_u32` answers its argument's 32-bit pattern.
#
# THIS FILE IS NEVER PART OF THE SOURCE HANDED TO CORE. It is not a unit and
# no manifest lists it. Packed into a CORE source, its definitions would meet
# the intrinsics they share a name with, and the build refuses that
# (`conflicting-intrinsic`) wherever the closure calls one.
module CoreIntrinsics
  class Arithmetic < StandardError; end

  I32 = (-(2**31)..(2**31 - 1)).freeze

  def self.operands(name, *xs)
    xs.each do |x|
      raise Arithmetic, "#{name}: #{x.inspect} is not an Integer" unless x.is_a?(Integer)
      raise Arithmetic, "#{name}: operand #{x} is outside the i32 range" unless I32.cover?(x)
    end
  end

  # the low 32 bits of an Integer, read as two's complement
  def self.low32(v)
    w = v & 0xffffffff
    w >= 0x80000000 ? w - 0x100000000 : w
  end
end

def core_w32_add(a, b)
  CoreIntrinsics.operands(:core_w32_add, a, b)
  CoreIntrinsics.low32(a + b)
end

def core_w32_sub(a, b)
  CoreIntrinsics.operands(:core_w32_sub, a, b)
  CoreIntrinsics.low32(a - b)
end

def core_w32_mul(a, b)
  CoreIntrinsics.operands(:core_w32_mul, a, b)
  CoreIntrinsics.low32(a * b)
end

def core_w32_neg(a)
  CoreIntrinsics.operands(:core_w32_neg, a)
  CoreIntrinsics.low32(-a)
end

def core_u32_lt(a, b)
  CoreIntrinsics.operands(:core_u32_lt, a, b)
  (a & 0xffffffff) < (b & 0xffffffff)
end

def core_u32_le(a, b)
  CoreIntrinsics.operands(:core_u32_le, a, b)
  (a & 0xffffffff) <= (b & 0xffffffff)
end

def core_u32_gt(a, b)
  CoreIntrinsics.operands(:core_u32_gt, a, b)
  (a & 0xffffffff) > (b & 0xffffffff)
end

def core_u32_ge(a, b)
  CoreIntrinsics.operands(:core_u32_ge, a, b)
  (a & 0xffffffff) >= (b & 0xffffffff)
end

def core_u32_shr(a, n)
  CoreIntrinsics.operands(:core_u32_shr, a, n)
  raise CoreIntrinsics::Arithmetic, "core_u32_shr: count #{n} is outside 0..31" unless (0..31).cover?(n)
  CoreIntrinsics.low32((a & 0xffffffff) >> n)
end

# DG/m_fixed.c's FixedMul: the exact product, shifted, its low 32 bits
def core_fixed_mul(a, b)
  CoreIntrinsics.operands(:core_fixed_mul, a, b)
  CoreIntrinsics.low32((a * b) >> 16)
end

# examples/doom/core/src/fixed.rb's fixed_div, after the operand check
def core_fixed_div(a, b)
  CoreIntrinsics.operands(:core_fixed_div, a, b)
  return (a ^ b).negative? ? -(2**31) : 2**31 - 1 if (a.abs >> 14) >= b.abs

  n = a << 16
  q = n.abs / b.abs
  CoreIntrinsics.low32((n ^ b).negative? ? -q : q)
end

# Decision 0042 stage 4. The 64-bit forms take Integers in the i64 range and
# answer the low 64 bits of the exact result, read as two's complement.
module CoreIntrinsics
  I64 = (-(2**63)..(2**63 - 1)).freeze

  def self.operands64(name, *xs)
    xs.each do |x|
      raise Arithmetic, "#{name}: #{x.inspect} is not an Integer" unless x.is_a?(Integer)
      raise Arithmetic, "#{name}: operand #{x} is outside the i64 range" unless I64.cover?(x)
    end
  end

  def self.low64(v)
    w = v & 0xffffffffffffffff
    w >= 0x8000000000000000 ? w - 0x10000000000000000 : w
  end

  # Ruby's `a << n` for any n (a negative n shifts right); the caller keeps
  # the low bits it needs. A count far past the width needs no huge Integer.
  def self.shift_left(a, n, width)
    return 0 if n >= width
    return a >> [-n, width - 1].min if n.negative?

    a << n
  end
end

# The low 32 bits of Ruby's `a << n`, for every n.
def core_w32_shl(a, n)
  CoreIntrinsics.operands(:core_w32_shl, a, n)
  CoreIntrinsics.low32(CoreIntrinsics.shift_left(a, n, 32))
end

def core_w64_add(a, b)
  CoreIntrinsics.operands64(:core_w64_add, a, b)
  CoreIntrinsics.low64(a + b)
end

def core_w64_sub(a, b)
  CoreIntrinsics.operands64(:core_w64_sub, a, b)
  CoreIntrinsics.low64(a - b)
end

def core_w64_mul(a, b)
  CoreIntrinsics.operands64(:core_w64_mul, a, b)
  CoreIntrinsics.low64(a * b)
end

def core_w64_neg(a)
  CoreIntrinsics.operands64(:core_w64_neg, a)
  CoreIntrinsics.low64(-a)
end

# The low 64 bits of Ruby's `a << n`, for every n.
def core_w64_shl(a, n)
  CoreIntrinsics.operands64(:core_w64_shl, a, n)
  CoreIntrinsics.low64(CoreIntrinsics.shift_left(a, n, 64))
end

def core_u64_lt(a, b)
  CoreIntrinsics.operands64(:core_u64_lt, a, b)
  (a & 0xffffffffffffffff) < (b & 0xffffffffffffffff)
end

def core_u64_le(a, b)
  CoreIntrinsics.operands64(:core_u64_le, a, b)
  (a & 0xffffffffffffffff) <= (b & 0xffffffffffffffff)
end

def core_u64_gt(a, b)
  CoreIntrinsics.operands64(:core_u64_gt, a, b)
  (a & 0xffffffffffffffff) > (b & 0xffffffffffffffff)
end

def core_u64_ge(a, b)
  CoreIntrinsics.operands64(:core_u64_ge, a, b)
  (a & 0xffffffffffffffff) >= (b & 0xffffffffffffffff)
end

def core_u64_shr(a, n)
  CoreIntrinsics.operands64(:core_u64_shr, a, n)
  raise CoreIntrinsics::Arithmetic, "core_u64_shr: count #{n} is outside 0..63" unless (0..63).cover?(n)
  CoreIntrinsics.low64((a & 0xffffffffffffffff) >> n)
end

# The pattern of an Integer in 0..2**32-1, read as a signed i32. CORE takes
# only a literal here and folds it.
def core_u32(x)
  raise CoreIntrinsics::Arithmetic, "core_u32: #{x.inspect} is not an Integer" unless x.is_a?(Integer)
  raise CoreIntrinsics::Arithmetic, "core_u32: #{x} is outside 0..4294967295" unless (0..0xffffffff).cover?(x)
  CoreIntrinsics.low32(x)
end
