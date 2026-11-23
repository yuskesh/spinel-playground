# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Walking a linked structure: `t` is READ OUT OF A BUFFER and then rebound on
# both arms of a branch. Every other fixture here indexes with a counter, so
# none of them has a local whose value came from a buffer crossing a join --
# and that is the shape the producer's hosted-Ruby `nullable_int` analysis
# calls nullable, because in hosted Ruby `link[i]` off the end is nil. It
# cannot be nil here: the contract declares the count and an access outside it
# is SPINEL_CORE_BOUNDS. refuse/nil_if_no_else.rb and refuse/nil_while_value.rb
# are the other half of this check -- the two shapes that really are nil in
# this subset, still refused.
#
# The walk is bounded by the buffer's own count, so a link that points into a
# cycle ends the loop instead of running forever. A well-formed chain of `n`
# cells is at most `n` steps, so the bound never ends a good walk early.

def walk_links(link, n_link)
  t = link[0]
  steps = 0
  seen = 0
  while t != 0
    nxt = link[t]
    if steps >= n_link
      nxt = 0
    else
      seen = seen + 1
    end
    steps = steps + 1
    t = nxt
  end
  seen
end
