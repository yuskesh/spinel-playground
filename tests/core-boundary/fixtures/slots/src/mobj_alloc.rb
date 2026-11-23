# Extracted for decision 0007 task 5 from the Full mobj slot allocator.
#
#   original: examples/doom/lib/doom/game.rb (Doom::Game#alloc_mobj)
#   upstream: DG/p_mobj.c, the zone allocation P_SpawnMobj does, via R007 4.8
#
# The same allocator as the thinkers' -- a LIFO free list in front of a bump
# allocator over a fixed capacity -- over a DIFFERENT array and with no list to
# link into. It is extracted beside the thinker one rather than shared with it
# because the original keeps them separate: the free list is threaded through
# `@thing_next`, which is the sector link field a live mobj uses for something
# else entirely, and that reuse is the thing a reference model has to get right
# rather than a detail to abstract away.
#
# The adaptations are thinker_add.rb's 1 to 3: the two scalars become a
# two-element `inout` buffer, `raise LevelError, "mobj overflow"` becomes
# `core_fail(:capacity)`, and `@mobj_alloc >= MAXMOBJS` becomes
# `a >= n_thing` over the same array's own count. `room` is adaptation 4's
# reason -- `&&` is not in the subset.
#
# Note what is NOT here. `alloc_mobj` returns a slot whose fields still hold
# whatever the previous occupant left; the original's `spawn_mobj` writes all
# thirty of them straight afterwards. Clearing them here would be a kindness
# the original does not do, and the reference model would then disagree with
# the original rather than with this.

def mobj_alloc(thing_next, n_thing, state, n_state)
  f = state[0]
  a = state[1]
  room = 1
  if f < 0
    if a >= n_thing
      room = 0
    else
      room = 1
    end
  else
    room = 1
  end
  if room == 0
    core_fail(:capacity)
  else
    if f >= 0
      state[0] = thing_next[f]
      f
    else
      state[1] = a + 1
      a
    end
  end
end
