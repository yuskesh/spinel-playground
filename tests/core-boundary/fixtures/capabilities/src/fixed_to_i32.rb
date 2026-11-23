# Extracted for decision 0007 task 5 from the Full helper.
#
#   original: examples/doom/lib/doom/fixed.rb (module Doom::Fixed)
#   upstream: DG/m_fixed.c, via R007 section 4.7
#
# Every adaptation is listed in this file. The rule is that the ADAPTED source
# and the original must agree on every case in the table, checked under CRuby,
# so an adaptation that changed the meaning is caught rather than argued about.

# `Doom::Fixed.to_i32` -- the C cast `(fixed_t)v` from DG/m_fixed.c, verbatim.
#
# Adaptations: none at all. The original's ternary is in the checked subset
# unchanged -- measured, after this file had first rewritten it into an if/else
# and claimed no adaptation while carrying one. A ternary needs both arms, which
# this one has; it is `unless` without an else, and `if` without one, that the
# subset refuses.

def fixed_to_i32(v)
  w = v & 0xffffffff
  w >= 0x80000000 ? w - 0x100000000 : w
end
