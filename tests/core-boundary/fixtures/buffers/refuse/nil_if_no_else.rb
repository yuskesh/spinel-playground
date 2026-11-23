# A refusal fixture for decision 0007 task 3. Not a case in the descriptor
# table: it exists to be rejected, and buffers.sh declares the diagnostic it
# must be rejected with.

# An `if` with no else, taken AS A VALUE. The false path produces nothing, so
# what the assignment receives is nil, and nil is not in this subset.
#
# THE SHAPE CHANGED, and why is worth recording. As first written this was
#
#     t = link[0]
#     if n_link > 3
#       t = 0
#     end
#     t
#
# and it was refused -- but not for nil. That `if` is in STATEMENT position and
# `t` already has a value on both paths; the refusal came from decision 0007's
# rule that both arms must exist, which was broader than the nil it was
# defending against. Decision 0008 task 4 narrowed the rule to value position,
# this fixture started building, and the test that found it is what says the
# old shape was never a nil case. The form below is one: the `if` IS the value.
#
# This fixture guards a NARROWING. The producer's own `nullable_int` analysis
# answers about hosted Ruby, where `buf[i]` off the end is nil; the checked
# route has no nil there, because the contract declares each buffer's count and
# an access outside it is SPINEL_CORE_BOUNDS. So with facts supplied the
# derivation answers instead -- otherwise the ordinary shape of walking a
# linked structure, where a local read from a buffer is rebound on both arms of
# a branch, was refused for a nil that cannot occur. Walk_links exercises that
# shape; this fixture and nil_while_value are the other half: a value that
# really is nil here must still be refused, and by the derivation.

def nil_if_no_else(link, n_link)
  t = if n_link > 3
        link[0]
      end
  t
end
