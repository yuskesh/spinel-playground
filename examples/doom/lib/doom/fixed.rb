# doom/lib/doom/fixed.rb
#
# 16.16 fixed point (`fixed_t`) and BAM angles (`angle_t`).
#
# **By the port's conventions there is no wrapper class.** Values are plain `Integer`s, and
# **truncation to 32 bits is written as an explicit `to_i32`**. `FixedMul` is called tens of
# thousands of times per frame, so object creation (GC 24 B / malloc 72 B) is ruled out in principle.
#
# Why this was the first work of the level stage: the convention was set, but the first stage
# used no fixed point at all, so it had not been checked in practice.
#
# **There are 3 differences from C's semantics, all absorbed here**:
#
#   1. `fixed_t` is int32, so `FixedMul`'s 64-bit intermediate is truncated by the return.
#      Ruby's Integer is 64-bit, so no truncation happens -> write `to_i32` explicitly.
#   2. C's `/` truncates toward 0; **Ruby's `/` truncates toward the floor**.
#      A negative division is off by 1 -> use `cdiv`.
#   3. `abs(a)` in `FixedDiv`'s guard **matches Ruby's `Integer#abs` (the mathematical
#      absolute value)**. Research had warned that "C's `abs(INT_MIN)` stays INT_MIN, so
#      implement a 32-bit abs", but **measuring the reference build showed the opposite**:
#      the optimizer uses the undefined-behaviour assumption that `abs()` returns a non-negative
#      value, so `abs(INT_MIN)` behaves as `2147483648` (told apart by 76 pairs).
#      Writing a 32-bit abs makes **the answer split there alone**.
#
# All 3 are checked every time by a gate that matches the reference implementation's
# FixedMul/FixedDiv on 242 514 pairs.

module Doom
  module Fixed
    FRACBITS = 16
    FRACUNIT = 65536
    I32_MIN = -2147483648
    I32_MAX = 2147483647

    # Truncation to int32. C's `(fixed_t)v` cast itself.
    def self.to_i32(v)
      w = v & 0xffffffff
      w >= 0x80000000 ? w - 0x100000000 : w
    end

    # Truncation to uint32 (angle_t's invariant: always kept as 0 <= v < 2^32).
    def self.bam(v)
      v & 0xffffffff
    end

    # `DG/m_fixed.c:FixedMul`: takes `((int64_t)a * (int64_t)b) >> FRACBITS` as
    # `fixed_t` (int32). `a * b` is at most 2^62, so it fits in 64 bits.
    def self.mul(a, b)
      w = ((a * b) >> 16) & 0xffffffff
      w >= 0x80000000 ? w - 0x100000000 : w
    end

    # C's `/` (truncation toward 0). Ruby's `/` goes to the floor, so it is off by 1 for negatives.
    def self.cdiv(n, d)
      q = (n < 0 ? -n : n) / (d < 0 ? -d : d)
      (n < 0) == (d < 0) ? q : -q
    end

    # `DG/m_fixed.c:FixedDiv` (= vanilla's integer version). linuxdoom's `FixedDiv2`,
    # which goes through double, is not used.
    def self.div(a, b)
      if (a.abs >> 14) >= b.abs
        (a ^ b) < 0 ? I32_MIN : I32_MAX
      else
        n = a << 16
        q = (n < 0 ? -n : n) / (b < 0 ? -b : b)
        q = -q unless (n < 0) == (b < 0)
        w = q & 0xffffffff
        w >= 0x80000000 ? w - 0x100000000 : w
      end
    end
  end
end
