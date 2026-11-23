# examples/doom/core/src/fixed.rb — the fixed-point and angle helpers.
#
# GPL-derived, from `examples/doom/lib/doom/fixed.rb` (`module Doom::Fixed`),
# which is itself derived from doomgeneric's `DG/m_fixed.c` and `DG/tables.h`
# via decision R007 section 4.7. See ../NOTICE.md and ../sources.tsv.
#
# THE ADAPTATIONS ARE STAGE 1'S, NOT NEW ONES. Every definition here is the
# body decision 0007 task 5 extracted and proved, unchanged:
# tests/core-boundary/fixtures/capabilities/src/ holds them one to a file with
# their declarations, and tests/core-boundary/capabilities.sh measures them
# against CRuby running the same definitions. What is new is only the packing:
# five files become one source unit, because a CORE entry is compiled from one
# file and `tools/doom/pack-core.rb` is what makes several into one.
#
# So this unit DEFINES AND RUNS NOTHING. No `module`, no `require_relative`, no
# top-level statement. The packer refuses all three, and the reason it refuses
# them is that a packed unit has to mean the same thing wherever in the packed
# file it lands.
#
# NO ENTRY CALLS THESE SINCE DECISION 0022. The three entries compute at 32 bits
# with the word intrinsics (core_w32_*, core_fixed_mul, core_fixed_div). The
# definitions stay, unchanged, for the int64 units the entries do not pack
# (bspwalk.rb, rvgpu.rb) and the CRuby models that load them.
#
# The names keep their `fixed_` prefix because a packed file is one namespace:
# `Doom::Fixed.mul` and `Doom::Fixed.div` are distinguished by their module,
# and `mul` and `div` alone would not be.

# The int32 truncation, which is C's `(fixed_t)v` cast. Ruby's Integer does not
# truncate, so the cast is written out.
I32_MIN = -2147483648
I32_MAX = 2147483647

def fixed_to_i32(v)
  w = v & 0xffffffff
  w >= 0x80000000 ? w - 0x100000000 : w
end

# `DG/m_fixed.c:FixedMul`. The 64-bit intermediate is truncated by the return
# type; `a * b` reaches 2^62 at most, so it fits before the shift.
def fixed_mul(a, b)
  w = ((a * b) >> 16) & 0xffffffff
  w >= 0x80000000 ? w - 0x100000000 : w
end

# C's `/`, which truncates toward zero. Ruby's `/` floors, so the two differ by
# one on a negative quotient and every DOOM division goes through this.
def fixed_cdiv(n, d)
  q = (n < 0 ? -n : n) / (d < 0 ? -d : d)
  (n ^ d) < 0 ? -q : q
end

# `DG/m_fixed.c:FixedDiv`, the integer version. The guard's `abs` is Ruby's,
# which is the mathematical absolute value; R007 4.7 predicted a 32-bit `abs`
# would be needed and the reference build measured the opposite, so writing one
# would split the answer exactly there.
def fixed_div(a, b)
  if (a.abs >> 14) >= b.abs
    (a ^ b) < 0 ? I32_MIN : I32_MAX
  else
    n = a << 16
    q = (n < 0 ? -n : n) / (b < 0 ? -b : b)
    q = (n ^ b) < 0 ? -q : q
    w = q & 0xffffffff
    w >= 0x80000000 ? w - 0x100000000 : w
  end
end

# `DG/tables.h`, the binary angle measure. A DOOM angle is a full turn in 32
# unsigned bits, so normalising one is the mask and nothing else. The result
# reaches 4294967295, which is not an i32: this entry answers i64 where the
# other four answer i32, and declaring it i32 would refuse every angle at or
# above ANG180.
def fixed_bam(v)
  v & 0xffffffff
end
