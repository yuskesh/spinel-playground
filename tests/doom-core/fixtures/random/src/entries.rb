# Entry wrappers for the ported generator: a boundary declares each buffer's
# count, and the helpers take borrowed buffers.
def dc_pr(rndtable, n_rndtable, prndindex, n_prndindex, pcount, n_pcount)
  dc_p_random(rndtable, n_rndtable, prndindex, pcount)
end

# The menu's generator gets its own entry, because the whole point of the port
# is that it is a SECOND definition over a second index. Compiling only
# `dc_p_random` would leave the separation checked in CRuby alone.
def dc_mr(rndtable, n_rndtable, rndindex, n_rndindex, mcount, n_mcount)
  dc_m_random(rndtable, n_rndtable, rndindex, mcount)
end

# And clearing, which must leave the counters standing.
def dc_cr(prndindex, n_prndindex, rndindex, n_rndindex)
  dc_clear_random(prndindex, rndindex)
end
