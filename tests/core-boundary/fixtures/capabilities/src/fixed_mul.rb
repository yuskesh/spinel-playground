# Extracted for decision 0007 task 5 from the Full helper.
#
#   original: examples/doom/lib/doom/fixed.rb (module Doom::Fixed)
#   upstream: DG/m_fixed.c, via R007 section 4.7
#
# Every adaptation is listed in this file. The rule is that the ADAPTED source
# and the original must agree on every case in the table, checked under CRuby,
# so an adaptation that changed the meaning is caught rather than argued about.

# `Doom::Fixed.mul` -- DG/m_fixed.c:FixedMul, `((int64_t)a * (int64_t)b) >>
# FRACBITS` taken back into fixed_t.
#
# Adaptations: none. A ternary with both arms is in the checked subset --
# measured, after this file had rewritten one into an if/else and said the
# subset required it. The multiplication becomes a checked one, which is
# machinery rather than meaning: for fixed_t inputs the product is at most
# 2^62.

def fixed_mul(a, b)
  w = ((a * b) >> 16) & 0xffffffff
  w >= 0x80000000 ? w - 0x100000000 : w
end
