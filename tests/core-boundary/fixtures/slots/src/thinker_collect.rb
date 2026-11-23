# Extracted for decision 0007 task 5 from the Full thinker list.
#
#   original: examples/doom/lib/doom/game.rb (Doom::Game#run_thinkers, its
#             sweep, together with #free_thinker which the sweep calls)
#   upstream: DG/p_tick.c:P_RunThinkers and Z_Free, via R007 4.8
#
# THE DISPATCH IS NOT EXTRACTED, and that is where the boundary is. The
# original's loop does two separable things: it walks the list unlinking and
# freeing whatever `P_RemoveThinker` marked, and it calls a thinker function
# for everything else. The second is the game, reached through a table of ten
# kinds; the first is list surgery over a fixed capacity, which is what CORE is
# for. So this takes the sweep and leaves the dispatch in Full, and the lane
# drives the ORIGINAL with every live slot marked TH_NULL -- a value none of
# the original's ten branches match, so its own sweep runs with no thinker
# function called, and the comparison is against the original's code rather
# than a copy of it.
#
# Adaptations 1 to 3 are thinker_add.rb's: the two scalars become a two-element
# `inout` buffer, `core_fail(:capacity)` replaces the raise, and the named
# constants are named here because a CORE root is its own closure.
#
# Adaptation 4: `free_thinker(t)` is inlined. A helper may not take a declared
# buffer, so it cannot be called with the arrays; the four lines are the
# original's, in the original's order.
#
# ADAPTATION 5 IS NOT A SPELLING CHANGE, and it is the only one in this
# capability. The walk is BOUNDED by `n_func`. The original is not, and neither
# is vanilla: a list whose `th_next` chain closes on itself walks forever in
# both. That is tolerable in a hosted game that built the list itself and is
# not tolerable in a CORE kernel, which takes the arrays from a caller it does
# not get to trust, so a cycle answers SPINEL_CORE_CAPACITY after at most
# `n_func` steps instead of not answering at all. It cannot end a good walk
# early: a well-formed chain over `n_func` cells visits at most `n_func - 1` of
# them, the sentinel not being one. The buffers already refuse an index outside
# themselves; this refuses a chain that stays inside them and never ends.
#
# That it cannot end a good walk early is MEASURED, at both ends. The trace
# takes the live list to thirteen, so a bound tightened to five or eight is
# caught there; the exhaustion lane sweeps a FULL list of 4095 and requires
# SPINEL_CORE_OK with nothing freed, which catches any bound below the
# capacity. mutations.tsv carries the first as a control.
#
# WHICH of the five counts bounds the walk is NOT observable, and saying so is
# better than implying it was checked: `steps >= n_next` is the same program
# here. Every count is an equally good answer to "at most how many slots can a
# well-formed chain visit". `n_func` is written because it is the array whose
# length the original's MAXTHINKERS is.

TH_REMOVED = 0
TH_NULL = 10

def thinker_collect(th_func, n_func, th_data, n_data,
                    th_next, n_next, th_prev, n_prev, state, n_state)
  freed = 0
  steps = 0
  runaway = 0
  t = th_next[0]
  while t != 0
    nxt = th_next[t]
    if steps >= n_func
      runaway = 1
      nxt = 0
    else
      if th_func[t] == TH_REMOVED
        th_next[th_prev[t]] = th_next[t]
        th_prev[th_next[t]] = th_prev[t]
        th_func[t] = TH_NULL
        th_data[t] = -1
        th_prev[t] = state[0]
        state[0] = t
        freed = freed + 1
      else
        freed = freed
      end
    end
    steps = steps + 1
    t = nxt
  end
  if runaway == 1
    core_fail(:capacity)
  else
    freed
  end
end
