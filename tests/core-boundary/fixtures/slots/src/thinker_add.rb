# Extracted for decision 0007 task 5 from the Full thinker list.
#
#   original: examples/doom/lib/doom/game.rb (Doom::Game#add_thinker)
#   upstream: DG/p_tick.c:P_AddThinker, via R007 4.8
#
# Every adaptation is listed in this file, and the rule is the one the other
# extractions follow: the ADAPTED source and the ORIGINAL must agree, checked
# under CRuby, before any compiler is involved. Here they must also agree with
# an INDEPENDENT MODEL, which is what decision 0007 asks for at this bullet:
# two spellings of the same pointer surgery agreeing with each other would
# only show that the transcription was faithful, not that it was right.
#
# THE STATE IS FOUR PARALLEL ARRAYS AND TWO SCALARS, and that is the original's
# shape, not a flattening invented here. Slot 0 is the sentinel -- vanilla's
# `thinkercap` -- so the live list is circular and doubly linked through it,
# and the free list is singly linked through `th_prev`, reusing the field a
# free slot has no other use for. `state` carries the two scalars a CORE entry
# cannot keep between calls: [0] is the free-list head (-1 when empty) and [1]
# is the bump allocator's next never-used slot.
#
# Adaptation 1: the two scalars become a two-element `inout` buffer. A CORE
# entry has no instance to hold `@th_free` and `@th_alloc` across calls, and a
# scalar parameter is by value. This is the only place the extraction holds
# state differently from the original; everything else is the same cells.
#
# Adaptation 2: `raise LevelError, "thinker overflow"` becomes
# `core_fail(:capacity)`. Exhausting a fixed capacity is what that status is
# for, and decision 0007 admits `core_fail` only for this category. Under
# CRuby the oracle gives `core_fail` its meaning -- it raises, because in CORE
# it ends the call with a status and no result written.
#
# Adaptation 3: `@th_alloc >= MAXTHINKERS` becomes `a >= n_func`. MAXTHINKERS
# is both the capacity and the length of all four arrays in the original, and
# `n_func` is the contract's count for the same array, so this is the same
# comparison rather than a new limit.
#
# WHICH count it is can be seen from outside, and is checked. Handed four
# arrays of different lengths the entry compares against th_func's own count
# and indexes each array under its own, so `tadd-short-func` comes back
# CAPACITY where `tadd-short-next`, `-data`, `-prev` and `-state` come back
# BOUNDS. Without those five rows the five declared counts would be five names
# for one number and `a >= n_next` would be the same program.
#
# Adaptation 4: the original's two arms each end by linking the slot; here the
# slot is chosen first and linked once. Factoring the link into a helper is
# what one would write, and it is not available: a helper may not take a
# declared buffer (`type-evidence: parameter th_func is buffer`). `room` exists
# for the same kind of reason -- `f < 0 && a >= n_func` is `unsupported-node:
# AndNode`. Both limits are recorded for the last bullet rather than worked
# around silently.

def thinker_add(func, data, th_func, n_func, th_data, n_data,
                th_next, n_next, th_prev, n_prev, state, n_state)
  f = state[0]
  a = state[1]
  room = 1
  if f < 0
    if a >= n_func
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
      t = f
      state[0] = th_prev[f]
    else
      t = a
      state[1] = a + 1
    end
    th_func[t] = func
    th_data[t] = data
    p = th_prev[0]
    th_next[p] = t
    th_next[t] = 0
    th_prev[t] = p
    th_prev[0] = t
    t
  end
end
