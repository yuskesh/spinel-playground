# Extracted for decision 0007 task 5 from the Full helper.
#
#   original: examples/doom/lib/doom/fixed.rb (module Doom::Fixed)
#   upstream: DG/m_fixed.c, via R007 section 4.7
#
# Every adaptation is listed in this file. The rule is that the ADAPTED source
# and the original must agree on every case in the table, checked under CRuby,
# so an adaptation that changed the meaning is caught rather than argued about.

# `Doom::Fixed.div` -- DG/m_fixed.c:FixedDiv, vanilla's integer form.
#
# The GUARD IS PART OF THE HELPER and is extracted with it. Decision 0007 says
# so in as many words: its zero-divisor guard returns saturation, and that
# saturation is a successful result rather than an arithmetic failure. With
# `b` zero, `(a.abs >> 14) >= 0` is true for every `a`, so the division is
# never reached and the answer is INT32_MAX or INT32_MIN by the sign.
#
# Adaptation 1, and the only one. `q = -q unless (n < 0) == (b < 0)` becomes a
# ternary over the same local. `unless` without an else is
# `unsupported-node: UnlessNode`, and the sign test is the xor form for the
# reason fixed_cdiv gives: comparing two booleans with `==` is refused.
#
# Everything else is the original's, and two things this file once recorded as
# adaptations were not. A ternary with both arms is in the checked subset, so
# the absolute values and the truncation are spelled as the original spells
# them. `I32_MIN` and `I32_MAX` are named constants, which the subset admits,
# so they are named here rather than inlined -- that inlining had happened
# silently and was recorded nowhere at all, which is the worse of the two
# mistakes.
#
# `a.abs` is Ruby's mathematical absolute value, and that is what the
# reference build does too: `abs(INT_MIN)` behaves as 2147483648 there,
# because the optimiser uses the undefined-behaviour assumption that abs
# returns non-negative. A 32-bit abs would disagree exactly here (E047 3.1).

I32_MIN = -2147483648
I32_MAX = 2147483647

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
