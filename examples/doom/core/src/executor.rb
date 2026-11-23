# examples/doom/core/src/executor.rb — the job executor: a frame's jobs, in schedule order.
#
# GPL-derived, from `examples/doom/lib/doom/executor.rb` (`Doom::JobExecutor#run`,
# `#exec_wall`, `#exec_span`, `#exec_masked`), which draws doomgeneric's
# `r_draw.c` columns and spans (`R_DrawColumn`, `R_DrawSpan`,
# `R_DrawFuzzColumn`) from job records. See ../NOTICE.md and ../sources.tsv.
#
# THE SCHEDULE IS THE ORDER. `Jobs` records every column and span a frame
# issues in three banks -- wall, span, masked -- and the schedule says, entry by
# entry, which bank and which record. The executor walks the schedule and
# nothing else, because the order is part of the picture: a fuzz column reads
# the pixel above or below from what the earlier jobs already drew.
#
# Every bank, the schedule, the ring and the resources arrive as borrowed
# buffers -- the executor holds none of them -- and the schedule's length is a
# scalar field of `core_state`, named by its slot index. The frame constants are
# the one-element values Full prepared.
#
# `Jobs#check`, which validates the banks before the original runs them, is NOT
# here: it stays Full's for now, and the ledger says so.

EX_KIND_WALL = 0
EX_KIND_SPAN = 1
EX_WC_NF = 7
EX_SP_NF = 7
EX_MC_NF = 9
# `R_DrawFuzzColumn` darkens through colormap row 6, and walks a 50-entry table.
EX_FUZZ_CMAP = 6
EX_FUZZ_N = 50

# `exec_wall`: an opaque wall or sky column from the texture column atlas.
def dc_exec_wall(scr, cmap, atlas, wall, i, width, centery, vwx, vwy)
  b = i * EX_WC_NF
  yl = wall[b + 1]
  yh = wall[b + 2]
  count = yh - yl
  return 0 if count < 0
  ofs = wall[b + 5]
  cm = wall[b + 6] * 256
  fracstep = wall[b + 3]
  frac = core_w32_add(wall[b + 4], core_w32_mul(core_w32_sub(yl, centery), fracstep))
  o = (yl + vwy) * width + wall[b] + vwx
  k = 0
  while k <= count
    scr[o] = cmap[cm + atlas[ofs + ((frac >> 16) & 127)]]
    o += width
    frac = core_w32_add(frac, fracstep)
    k += 1
  end
  0
end

# `exec_span`: a plane span from the flat atlas, the packed position and step.
def dc_exec_span(scr, cmap, flat, span, i, width, vwx, vwy)
  b = i * EX_SP_NF
  x1 = span[b + 1]
  count = span[b + 2] - x1
  return 0 if count < 0
  ofs = span[b + 5]
  cm = span[b + 6] * 256
  o = (span[b] + vwy) * width + x1 + vwx
  position = span[b + 3]
  step = span[b + 4]
  k = 0
  while k <= count
    spot = core_u32_shr(position, 26) | ((position >> 4) & 0x0fc0)
    scr[o] = cmap[cm + flat[ofs + spot]]
    o += 1
    position = core_w32_add(position, step)
    k += 1
  end
  0
end

# `exec_masked`: a sprite or masked-texture column from the IWAD bytes or the
# ring -- or, with a fuzz phase, the fuzz column, which reads the screen it
# writes at the row the fuzz table names.
def dc_exec_masked(scr, cmap, wad, zonebuf, fuzzoffset, masked, i, width, centery, vwx, vwy)
  b = i * EX_MC_NF
  yl = masked[b + 1]
  yh = masked[b + 2]
  count = yh - yl
  return 0 if count < 0
  o = (yl + vwy) * width + masked[b] + vwx
  fz = masked[b + 8]
  if fz >= 0
    fp = fz
    k = 0
    while k <= count
      scr[o] = cmap[EX_FUZZ_CMAP * 256 + scr[o + fuzzoffset[fp] * width]]
      fp += 1
      fp = 0 if fp == EX_FUZZ_N
      o += width
      k += 1
    end
    return 1
  end
  sel = masked[b + 5]
  ofs = masked[b + 6]
  cm = masked[b + 7] * 256
  fracstep = masked[b + 3]
  frac = core_w32_add(masked[b + 4], core_w32_mul(core_w32_sub(yl, centery), fracstep))
  k = 0
  while k <= count
    t = ofs + ((frac >> 16) & 127)
    src = 0
    if sel == RES_ZONE
      src = zonebuf[t]
    else
      src = wad[t]
    end
    scr[o] = cmap[cm + src]
    o += width
    frac = core_w32_add(frac, fracstep)
    k += 1
  end
  0
end

# `JobExecutor#run`, after `Jobs#check`: every scheduled job, in order. Answers
# how many fuzz columns it drew, so a caller can see the fuzz path ran.
def dc_exec_run(scr, cmap, atlas, flat, wad, zonebuf, fuzzoffset, wall, span, masked,
                sc_kind, sc_idx, nsched, width, centery, vwx, vwy)
  fuzz = 0
  i = 0
  while i < nsched
    kind = sc_kind[i]
    j = sc_idx[i]
    if kind == EX_KIND_WALL
      dc_exec_wall(scr, cmap, atlas, wall, j, width, centery, vwx, vwy)
    elsif kind == EX_KIND_SPAN
      dc_exec_span(scr, cmap, flat, span, j, width, vwx, vwy)
    else
      fuzz += dc_exec_masked(scr, cmap, wad, zonebuf, fuzzoffset, masked, j, width, centery, vwx, vwy)
    end
    i += 1
  end
  fuzz
end
