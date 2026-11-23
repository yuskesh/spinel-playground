# spinel: int64
# examples/doom/core/src/random.rb — the DOOM pseudo-random generator.
#
# GPL-derived, from `examples/doom/lib/doom/random.rb` (`Doom::Random`), from
# doomgeneric's `M_Random`. See ../NOTICE.md and ../sources.tsv.
#
# TWO INDICES, NOT ONE, AND THE ORDER IS THE GAME. `P_Random` and `M_Random`
# walk the same 256-byte table with SEPARATE indices: the game's own draws
# advance `prndindex` and the menu's advance `rndindex`, and every demo's
# determinism rests on the first advancing exactly once per draw, in exactly
# the order the tick makes them. That is why these are two definitions and not
# one with a flag: a flag is a value someone could pass wrongly.
#
# THE TABLE IS A PREPARED RESOURCE. Full hands it over as 256 bytes; CORE
# indexes it and never builds it. The index is masked to 8 bits, which is the
# whole of the wraparound rule -- vanilla's `rndindex = (rndindex+1)&0xff`.
#
# THE COUNTERS ARE STATE, not instrumentation. `pcount` is what a demo
# comparison counts, so it lives in the schema beside the indices rather than
# in a trace buffer that a release build might not have.

# One game draw. The index advances first and the value is read at the NEW
# index -- not the old one, which is a difference of one draw across a whole
# demo and would show up as a divergence thousands of tics later.
def dc_p_random(rndtable, n_rndtable, prndindex, pcount)
  i = (prndindex[0] + 1) & 0xff
  prndindex[0] = i
  pcount[0] = pcount[0] + 1
  rndtable[i]
end

# One menu draw, on the other index. The melt wipe's 320 draws at tic 2 go
# through here, which is why a demo recorded by this program replays in the
# reference implementation.
def dc_m_random(rndtable, n_rndtable, rndindex, mcount)
  i = (rndindex[0] + 1) & 0xff
  rndindex[0] = i
  mcount[0] = mcount[0] + 1
  rndtable[i]
end

# `M_ClearRandom`: both indices, neither counter. The counters are how many
# draws happened and clearing them would lose that.
#
# NOT ON THE TICK PATH, and so it has no row in tools/doom/core-migrated.tsv:
# the original `Random#clear` is called from `G_InitNew` at level start, and
# the step entry's measured closure does not reach it. It is ported here with
# the generator it belongs to rather than left for whoever migrates level
# start, because the rule that clearing the indices must not clear the counters
# is a property OF THIS FILE and splitting it across two changes would lose it.
def dc_clear_random(prndindex, rndindex)
  prndindex[0] = 0
  rndindex[0] = 0
  0
end
