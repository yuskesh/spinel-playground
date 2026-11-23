# examples/doom/core/src/jobs.rb — the job banks' pushes and phase marks.
#
# GPL-derived, from `examples/doom/lib/doom/jobs.rb` (`Doom::Jobs#push_wall`,
# `#push_span`, `#push_masked`, `#mark_phase1`, `#mark_phase3`), which record
# the columns and spans doomgeneric's `r_segs.c`, `r_plane.c` and `r_things.c`
# hand to `r_draw.c`. See ../NOTICE.md and ../sources.tsv.
#
# A PUSH IS A RECORD AND A SCHEDULE ENTRY. The record goes into its bank at the
# bank's count, the bank's count goes up, and then the schedule gets the kind
# and the record's index at the schedule's count. The counts are scalar fields
# of `core_state`, named by their slot indices; the banks and the schedule are
# borrowed buffers; each capacity is a value Full prepares, a one-element
# buffer of its own. A full bank or a full schedule is CAPACITY, where the
# original raises `JobError` -- and, as there, a push refused at the schedule
# has already stored its record and counted it: nothing is rolled back. The
# schedule step is written out in each push, as the original writes it: a
# helper the three pushes shared would be reached from outside each entry's
# closure, which the kernel tool refuses.
#
# `Jobs#check`, which validates the banks before the executor runs them, is NOT
# here: it stays Full's.

JB_KIND_WALL = 0
JB_KIND_SPAN = 1
JB_KIND_MASKED = 2
JB_WC_NF = 7
JB_SP_NF = 7
JB_MC_NF = 9

# `push_wall`: an opaque wall or sky column.
def dc_push_wall(state, wall, sc_kind, sc_idx, cap_wall, cap_sched, i_nwall, i_nsched,
                 x, yl, yh, iscale, texmid, srcofs, cmap)
  i = state[i_nwall]
  if i >= cap_wall[0]
    core_fail(:capacity)
  end
  b = i * JB_WC_NF
  wall[b] = x
  wall[b + 1] = yl
  wall[b + 2] = yh
  wall[b + 3] = iscale
  wall[b + 4] = texmid
  wall[b + 5] = srcofs
  wall[b + 6] = cmap
  state[i_nwall] = i + 1
  s = state[i_nsched]
  if s >= cap_sched[0]
    core_fail(:capacity)
  end
  sc_kind[s] = JB_KIND_WALL
  sc_idx[s] = i
  state[i_nsched] = s + 1
  0
end

# `push_span`: a plane span, its position and step packed.
def dc_push_span(state, span, sc_kind, sc_idx, cap_span, cap_sched, i_nspan, i_nsched,
                 y, x1, x2, position, step, srcofs, cmap)
  i = state[i_nspan]
  if i >= cap_span[0]
    core_fail(:capacity)
  end
  b = i * JB_SP_NF
  span[b] = y
  span[b + 1] = x1
  span[b + 2] = x2
  span[b + 3] = position
  span[b + 4] = step
  span[b + 5] = srcofs
  span[b + 6] = cmap
  state[i_nspan] = i + 1
  s = state[i_nsched]
  if s >= cap_sched[0]
    core_fail(:capacity)
  end
  sc_kind[s] = JB_KIND_SPAN
  sc_idx[s] = i
  state[i_nsched] = s + 1
  0
end

# `push_masked`: a sprite or masked-texture column, or a fuzz column.
def dc_push_masked(state, masked, sc_kind, sc_idx, cap_masked, cap_sched, i_nmasked, i_nsched,
                   x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz)
  i = state[i_nmasked]
  if i >= cap_masked[0]
    core_fail(:capacity)
  end
  b = i * JB_MC_NF
  masked[b] = x
  masked[b + 1] = yl
  masked[b + 2] = yh
  masked[b + 3] = iscale
  masked[b + 4] = texmid
  masked[b + 5] = srcres
  masked[b + 6] = srcofs
  masked[b + 7] = cmap
  masked[b + 8] = fuzz
  state[i_nmasked] = i + 1
  s = state[i_nsched]
  if s >= cap_sched[0]
    core_fail(:capacity)
  end
  sc_kind[s] = JB_KIND_MASKED
  sc_idx[s] = i
  state[i_nsched] = s + 1
  0
end

# `mark_phase1`: the walls pushed so far are phase 0.
def dc_mark_phase1(state, i_nwall, i_wall_phase0_n)
  state[i_wall_phase0_n] = state[i_nwall]
  0
end

# `mark_phase3`: the masked columns pushed so far are phase 2.
def dc_mark_phase3(state, i_nmasked, i_masked_phase2_n)
  state[i_masked_phase2_n] = state[i_nmasked]
  0
end
