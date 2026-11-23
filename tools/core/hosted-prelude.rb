# tools/core/hosted-prelude.rb -- the CORE intrinsics (decisions 0022 and
# 0042) for the hosted half of a build and for the contract reader.
#
# The CORE routes lower these names in place (spinel-mlir/Core/Intrinsics.h).
# This file gives the same names to two other readers of the same source:
#
#   * tools/core/spinel-core-build places it before the program, after the
#     source's leading comment lines, in the copy of the source that the
#     pinned Spinel compiles, so hosted code may call the intrinsics too;
#   * on `--core` and freestanding, the contract reader analyses the source
#     with this file placed the same way, so a call to an intrinsic has a
#     type. Its own nodes are dropped, and the source's moved back to their
#     own lines, before anything reads the analysis.
#
# Each copy gets only the definitions of the names the source spells. They
# go before the program because a call that runs before a method's first
# definition is a NoMethodError (upstream Spinel 1782a9e13).
#
# It is never part of the core source, and it defines nothing but the
# intrinsics' names. Rules for editing it:
#
#   * no operation may overflow 64 bits: the pinned Spinel compiles it in its
#     default `--int-overflow=raise` mode;
#   * every name a 32-bit body admits (all but the `w64` and `u64` ones) uses
#     only literals in the i32 range, and its result never depends on the
#     type of an argument the reader may read as wider (`core_u32`'s
#     literal): the reader analyses a 32-bit body at 32 bits, where a wider
#     value would make the caller's values wider too;
#   * a failure raises RangeError with exactly the text the core object's
#     failure hook prints for it (kind 4, spinel-mlir/Core/Intrinsics.h).
#
# tools/core/intrinsics.rb is the same vocabulary for CRuby.

def core_w32_add(a, b)
  raise RangeError, "core_w32_add: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  s = a + b
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

def core_w32_sub(a, b)
  raise RangeError, "core_w32_sub: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  s = a - b
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

def core_w32_mul(a, b)
  raise RangeError, "core_w32_mul: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  s = a * b
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

def core_w32_neg(a)
  raise RangeError, "core_w32_neg: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647
  s = 0 - a
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

# The low 32 bits of Ruby's `a << n` for every n: a negative n shifts right.
def core_w32_shl(a, n)
  raise RangeError, "core_w32_shl: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && n >= -2147483647 - 1 && n <= 2147483647
  return 0 if n >= 32
  return a >> (n <= -32 ? 31 : 0 - n) if n < 0
  s = a << n
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

# The unsigned order: flipping the sign bit maps 0..2**32-1 onto the signed
# order.
def core_u32_lt(a, b)
  raise RangeError, "core_u32_lt: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  (a ^ (-2147483647 - 1)) < (b ^ (-2147483647 - 1))
end

def core_u32_le(a, b)
  raise RangeError, "core_u32_le: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  (a ^ (-2147483647 - 1)) <= (b ^ (-2147483647 - 1))
end

def core_u32_gt(a, b)
  raise RangeError, "core_u32_gt: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  (a ^ (-2147483647 - 1)) > (b ^ (-2147483647 - 1))
end

def core_u32_ge(a, b)
  raise RangeError, "core_u32_ge: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  (a ^ (-2147483647 - 1)) >= (b ^ (-2147483647 - 1))
end

def core_u32_shr(a, n)
  raise RangeError, "core_u32_shr: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && n >= -2147483647 - 1 && n <= 2147483647
  raise RangeError, "core_u32_shr: the count is outside 0..31" unless n >= 0 && n <= 31
  return a if n == 0
  (a >> n) & (2147483647 >> (n - 1))
end

# DG/m_fixed.c's FixedMul: the exact product, shifted, its low 32 bits.
def core_fixed_mul(a, b)
  raise RangeError, "core_fixed_mul: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  s = (a * b) >> 16
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

# examples/doom/core/src/fixed.rb's fixed_div: saturating, so a zero divisor
# saturates too.
def core_fixed_div(a, b)
  raise RangeError, "core_fixed_div: an operand is outside the i32 range" unless a >= -2147483647 - 1 && a <= 2147483647 && b >= -2147483647 - 1 && b <= 2147483647
  if (a.abs >> 14) >= b.abs
    return (a ^ b) < 0 ? -2147483647 - 1 : 2147483647
  end
  q = (a << 16).abs / b.abs
  s = (a ^ b) < 0 ? 0 - q : q
  (s & 2147483647) - ((s >> 31) & 1) * 1073741824 * 2
end

# The pattern of an Integer in 0..2**32-1, read as a signed i32. The result
# is built from its bits, so its type is an Integer whatever the reader
# makes of the literal.
def core_u32(x)
  raise RangeError, "core_u32: the value is outside 0..4294967295" unless x >= 0 && (x >> 16) <= 65535
  r = 0
  i = 0
  while i < 31
    r = r | (1 << i) if ((x >> i) & 1) == 1
    i += 1
  end
  r = r | (-2147483647 - 1) if ((x >> 31) & 1) == 1
  r
end

# The 64-bit forms. A 32-bit body refuses them, so their literals may be
# wide. Sums are taken in 32-bit halves and products in 16-bit limbs, so
# nothing overflows.
def core_w64_add(a, b)
  lo = (a & 0xffffffff) + (b & 0xffffffff)
  hi = (((a >> 32) & 0xffffffff) + ((b >> 32) & 0xffffffff) + (lo >> 32)) & 0xffffffff
  hi = hi - 0x100000000 if hi >= 0x80000000
  (hi << 32) | (lo & 0xffffffff)
end

# -a is ~a + 1, and a - b is a + ~b + 1: the carry into the low half is 1.
def core_w64_neg(a)
  lo = ((~a) & 0xffffffff) + 1
  hi = ((((~a) >> 32) & 0xffffffff) + (lo >> 32)) & 0xffffffff
  hi = hi - 0x100000000 if hi >= 0x80000000
  (hi << 32) | (lo & 0xffffffff)
end

def core_w64_sub(a, b)
  lo = (a & 0xffffffff) + ((~b) & 0xffffffff) + 1
  hi = (((a >> 32) & 0xffffffff) + (((~b) >> 32) & 0xffffffff) + (lo >> 32)) & 0xffffffff
  hi = hi - 0x100000000 if hi >= 0x80000000
  (hi << 32) | (lo & 0xffffffff)
end

def core_w64_mul(a, b)
  a0 = a & 0xffff
  a1 = (a >> 16) & 0xffff
  a2 = (a >> 32) & 0xffff
  a3 = (a >> 48) & 0xffff
  b0 = b & 0xffff
  b1 = (b >> 16) & 0xffff
  b2 = (b >> 32) & 0xffff
  b3 = (b >> 48) & 0xffff
  # each 16-bit column: at most four products below 2**32 and the carry
  c0 = a0 * b0
  c1 = a0 * b1 + a1 * b0 + (c0 >> 16)
  c2 = a0 * b2 + a1 * b1 + a2 * b0 + (c1 >> 16)
  c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + (c2 >> 16)
  hi = ((c3 & 0xffff) << 16) | (c2 & 0xffff)
  hi = hi - 0x100000000 if hi >= 0x80000000
  (hi << 32) | ((c1 & 0xffff) << 16) | (c0 & 0xffff)
end

# The low 64 bits of Ruby's `a << n` for every n: a negative n shifts right.
def core_w64_shl(a, n)
  return 0 if n >= 64
  return a >> (n <= -64 ? 63 : 0 - n) if n < 0
  return a if n == 0
  low = a & ((1 << (63 - n)) - 1)
  top = (a >> (63 - n)) & 1
  top == 1 ? (low << n) | -9223372036854775808 : low << n
end

def core_u64_lt(a, b)
  (a ^ -9223372036854775808) < (b ^ -9223372036854775808)
end

def core_u64_le(a, b)
  (a ^ -9223372036854775808) <= (b ^ -9223372036854775808)
end

def core_u64_gt(a, b)
  (a ^ -9223372036854775808) > (b ^ -9223372036854775808)
end

def core_u64_ge(a, b)
  (a ^ -9223372036854775808) >= (b ^ -9223372036854775808)
end

def core_u64_shr(a, n)
  raise RangeError, "core_u64_shr: the count is outside 0..63" unless n >= 0 && n <= 63
  return a if n == 0
  (a >> n) & (9223372036854775807 >> (n - 1))
end
