# spinel: int64
# examples/doom/core/src/thinkers.rb — the thinker slot list, as CORE source.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb` (`Doom::Game`), which is
# derived from doomgeneric's `p_tick.c`. See ../NOTICE.md and ../sources.tsv.
#
# THE SAME ALGORITHM, NOT A SECOND ONE. This is `add_thinker`, `free_thinker`
# and `remove_thinker` with their pointer assignments unchanged. What changes
# is where the state lives: the Full version reaches `@th_next` through `self`
# and this one receives the buffers, so the same list operations are written
# over borrowed buffers with a bound each call carries.
#
# The free list is the vanilla one and its shape is the point: a freed slot is
# pushed onto `th_free` through `th_prev`, so `th_prev` means two different
# things depending on whether the slot is live. Rewriting that into two arrays
# would be a different program with a different reuse order, and the reuse
# order is observable -- the reference dump's `slot` column is exactly it.
#
# `th_free` and `th_alloc` are single values and arrive as one-element
# buffers, which is what lets a helper receive them at all: 0007 gives CORE
# scalars and buffers, and a value the entry must UPDATE has to be a buffer.

# The values defs.rb declares, read off it rather than invented: a free slot's
# function is 10 and a removed one's is 0. Guessing 0 and 1 here would have
# made a freed slot look like a removed one, which the sweep treats very
# differently.
TH_NULL = 10
TH_REMOVED = 0

# Take a slot: the free list first, then the high-water mark. Answers the slot
# or -1 when the arena is full -- CAPACITY is the caller's to report, because
# only the caller knows whether a full arena is an error for what it was doing.
def dc_take_slot(th_free, th_prev, th_alloc, cap)
  f = th_free[0]
  if f >= 0
    th_free[0] = th_prev[f]
    f
  else
    a = th_alloc[0]
    if a >= cap
      -1
    else
      th_alloc[0] = a + 1
      a
    end
  end
end

# THE FUNCTION AND ITS DATA, stored into the slot between taking it and
# linking it -- which is exactly where `P_AddThinker` does it.
#
# This was MISSING, and Mac review of 33da4d9 found it: the migration row said
# `Game#add_thinker` became `dc_take_slot` and `dc_link_slot`, and those two
# together do not do what the original does. The store lived in
# tests/doom-core/slot-model.rb's own `port_add`, so the comparison passed
# while the ported code could not have been assembled from CORE source alone.
# A test supplying a step of the algorithm is the test answering its own
# question.
def dc_store_thinker(th_func, th_data, t, func, data)
  th_func[t] = func
  th_data[t] = data
  t
end

# Link a taken slot at the tail. Slot 0 is the list head and is never taken,
# which is why `th_prev[0]` is the tail pointer.
def dc_link_slot(th_next, th_prev, t)
  p = th_prev[0]
  th_next[p] = t
  th_next[t] = 0
  th_prev[t] = p
  th_prev[0] = t
  t
end

# Unlink a live slot. Both neighbours are updated before the slot is freed, so
# a traversal holding `th_next[t]` from before the unlink still walks the list
# the way vanilla's use-after-free does.
def dc_unlink_slot(th_next, th_prev, t)
  n = th_next[t]
  p = th_prev[t]
  th_next[p] = n
  th_prev[n] = p
  n
end

# Give a slot back. `th_prev` becomes the free-list link, which is the vanilla
# shape and the reason a freed slot must not be read as a live one.
def dc_free_slot(th_func, th_data, th_prev, th_free, t)
  th_func[t] = TH_NULL
  th_data[t] = -1
  th_prev[t] = th_free[0]
  th_free[0] = t
  t
end

# Mark a live slot for removal. The sweep is what unlinks it, on its own pass,
# which is what makes a removal during a traversal behave as vanilla's does.
def dc_mark_removed(th_func, t)
  th_func[t] = TH_REMOVED
  t
end
