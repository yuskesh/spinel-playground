# Extracted for decision 0007 task 5 from the Full helper.
#
#   original: examples/doom/lib/doom/fixed.rb (module Doom::Fixed)
#   upstream: DG/m_fixed.c, via R007 section 4.7
#
# Every adaptation is listed in this file. The rule is that the ADAPTED source
# and the original must agree on every case in the table, checked under CRuby,
# so an adaptation that changed the meaning is caught rather than argued about.

# `Doom::Fixed.cdiv` -- C's division, which truncates toward zero where Ruby's
# floors. Not a DG function: it is the `/` DG/m_fixed.c relies on.
#
# Adaptation 1: none where one was recorded. The absolute-value ternaries are
# in the checked subset unchanged; this file had replaced them with `n.abs` and
# called that an adaptation, and the ternaries are back.
#
# Adaptation 2: the sign test `(n < 0) == (d < 0)` becomes `(n ^ d) < 0`, with
# the arms swapped. Comparing two booleans with `==` is not in the checked
# subset -- a comparison there takes integers -- and the xor test is the one
# the original's `div` already uses. The sign bit of `n ^ d` is set exactly
# when the signs differ, so this is the same predicate inverted.

def fixed_cdiv(n, d)
  q = (n < 0 ? -n : n) / (d < 0 ? -d : d)
  (n ^ d) < 0 ? -q : q
end
