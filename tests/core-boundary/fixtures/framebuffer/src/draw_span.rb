# Extracted for decision 0007 task 5 from the Full job executor.
#
#   original: examples/doom/lib/doom/executor.rb (Doom::JobExecutor#exec_span)
#   upstream: DG/r_draw.c:R_DrawSpan, the packed form, via R009 section 7.2
#
# The adaptations are the three draw_wall.rb lists, and nothing more: the frame
# constants and job fields become parameters, `setbyte`/`getbyte` become `[]=`
# and `[]`, and `return if count < 0` becomes an if/else. Read that file for
# what each one costs; this one repeats only what is specific to the span.
#
# Adaptation 4 (span only): `position` is a parameter, so the loop variable is
# a separate local `pos`. The original assigns back over its own local, which a
# parameter here would also permit, but a parameter that is rebound and a frame
# constant that is not read differently at a glance, and the span's `position`
# is the only value in these three kernels that both arrives and advances.
#
# `spot = (position >> 26) | ((position >> 4) & 0x0fc0)` is the whole reason
# the job carries ONE `position` rather than separate x and y fractions: the
# flat lookup is a function of that single u32, which is what makes the span
# gatherable later (R009 section 3.3). It is copied unchanged.

M32 = 0xffffffff

def draw_span(scr, n_scr, flat, n_flat, cmap, n_cmap,
              x1, x2, y, srcofs, cmapidx, position, step,
              width, viewwindowx, viewwindowy)
  count = x2 - x1
  if count < 0
    0
  else
    cm = cmapidx * 256
    o = (y + viewwindowy) * width + x1 + viewwindowx
    pos = position
    i2 = 0
    while i2 <= count
      spot = (pos >> 26) | ((pos >> 4) & 0x0fc0)
      scr[o] = cmap[cm + flat[srcofs + spot]]
      o += 1
      pos = (pos + step) & M32
      i2 += 1
    end
    0
  end
end
