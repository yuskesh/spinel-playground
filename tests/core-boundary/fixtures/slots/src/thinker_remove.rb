# Extracted for decision 0007 task 5 from the Full thinker list.
#
#   original: examples/doom/lib/doom/game.rb (Doom::Game#remove_thinker)
#   upstream: DG/p_tick.c:P_RemoveThinker, via R007 4.8
#
# The original is one line, and so is this. It is here because REMOVAL IS
# DEFERRED and that is the whole design: `P_RemoveThinker` does not unlink
# anything, it marks the slot, and the next sweep does the unlinking. A
# removal that took effect at once would be a different program -- vanilla
# walks the list while thinkers remove themselves and each other, and the
# deferral is what makes that well defined.
#
# Adaptation: `TH_REMOVED` is named here rather than reached for from
# Doom::Defs, because a CORE root is its own closure. The value is the
# original's, 0.
#
# The slot index is not checked against the live list. Neither does the
# original: `P_RemoveThinker` marks whatever it is handed. What the CORE route
# adds is that an index outside the array is SPINEL_CORE_BOUNDS rather than a
# store into whatever follows, and slots.sh has the pair for it.

TH_REMOVED = 0

def thinker_remove(t, th_func, n_func)
  th_func[t] = TH_REMOVED
  0
end
