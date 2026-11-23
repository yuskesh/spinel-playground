# Entry wrappers for the ported slot operations.
#
# A CORE ENTRY declares each buffer's count as a scalar parameter, because the
# caller supplies the descriptor. A borrowed HELPER does not: its bound
# travels with the call (decision 0008 task 3). So the helpers in thinkers.rb
# take buffers and nothing else, and these wrappers are what give the boundary
# the counts it needs -- which is also what makes this fixture exercise the
# borrowed-call path rather than talking about it.
#
# There is no `require_relative` here: tools/doom/pack-core.rb is what makes
# the two units one file, and it refuses a unit that loads another.
def dc_take(th_free, n_th_free, th_prev, n_th_prev, th_alloc, n_th_alloc, cap)
  dc_take_slot(th_free, th_prev, th_alloc, cap)
end

def dc_link(th_next, n_th_next, th_prev, n_th_prev, t)
  dc_link_slot(th_next, th_prev, t)
end

def dc_unlink(th_next, n_th_next, th_prev, n_th_prev, t)
  dc_unlink_slot(th_next, th_prev, t)
end

def dc_free(th_func, n_th_func, th_data, n_th_data, th_prev, n_th_prev,
            th_free, n_th_free, t)
  dc_free_slot(th_func, th_data, th_prev, th_free, t)
end
