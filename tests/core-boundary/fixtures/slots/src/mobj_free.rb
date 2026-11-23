# Extracted for decision 0007 task 5 from the Full mobj slot allocator.
#
#   original: examples/doom/lib/doom/game.rb (Doom::Game#free_mobj)
#   upstream: DG/p_mobj.c:P_RemoveMobj, via R007 4.8
#
# Two lines, and both matter to what comes back out. The freed slot takes the
# old head as its successor and becomes the new head, so the list is LIFO and
# the NEXT allocation returns THE SLOT FREED MOST RECENTLY. That ordering is
# observable -- free b then a, and the next two allocations are a then b, not b
# then a -- so a reference model that used a queue would disagree here, which
# is the point of having one.
#
# The adaptation is thinker_add.rb's 1: the free-list head becomes `state[0]`
# in a two-element `inout` buffer.
#
# Nothing checks that the slot was allocated, or that it is not already on the
# free list. Neither does the original. Freeing one slot twice threads it to
# itself and the allocator then hands it out forever, which is a caller's error
# in both; what the CORE route adds is that an index outside the array is
# SPINEL_CORE_BOUNDS, and slots.sh has the pair for it.

def mobj_free(m, thing_next, n_thing, state, n_state)
  thing_next[m] = state[0]
  state[0] = m
  0
end
