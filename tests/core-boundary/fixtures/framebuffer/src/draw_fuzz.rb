# Extracted for decision 0007 task 5 from the Full job executor.
#
#   original: examples/doom/lib/doom/executor.rb (Doom::JobExecutor#exec_masked,
#             the `fz >= 0` arm)
#   upstream: DG/r_draw.c:R_DrawFuzzColumn, via R009 section 9.3
#
# The adaptations are draw_wall.rb's three, plus the two below.
#
# THE POINT OF THIS KERNEL is that it READS THE FRAMEBUFFER IT WRITES. Fuzz
# takes the pixel one row above or below and darkens it, so what it produces
# depends on what earlier jobs already drew there. Decision 0007 prescribes the
# shape for exactly this: one `inout` buffer and explicit indices, rather than
# a separate source and destination that would have to be declared to overlap.
# The screen is therefore the single `inout` buffer, and `o + fuzzoffset[fp] *
# width` is the explicit neighbouring index.
#
# Adaptation 5: the original takes the `fz >= 0` arm of `exec_masked`, which
# also holds the ordinary masked column. The two arms share nothing but the
# `o` computation -- the ordinary arm is `exec_wall`'s loop with a different
# source bank -- so the fuzz arm is extracted alone rather than carrying a
# source selection the fuzz path never uses.
#
# Adaptation 6: `fp = 0 if fp == 50` becomes an if/else, the same reason
# adaptation 3 gives, and 50 is named. The else arm assigns `fp` to itself,
# which is the form the buffer fixtures already use for a branch that has
# nothing to do: the checked subset wants both arms to define the value.
#
# `FUZZ_CMAP * 256` is `colormaps + 6*256` in r_draw.c -- fuzz always darkens
# by the same fixed row, never by the column's own light level, so there is no
# cmap field on the job.

FUZZ_CMAP = 6
FUZZ_N = 50

def draw_fuzz(scr, n_scr, cmap, n_cmap, fuzzoffset, n_fuzzoffset,
              yl, yh, x, fz, width, viewwindowx, viewwindowy)
  count = yh - yl
  if count < 0
    0
  else
    o = (yl + viewwindowy) * width + x + viewwindowx
    fp = fz
    i2 = 0
    while i2 <= count
      scr[o] = cmap[FUZZ_CMAP * 256 + scr[o + fuzzoffset[fp] * width]]
      fp += 1
      if fp == FUZZ_N
        fp = 0
      else
        fp = fp
      end
      o += width
      i2 += 1
    end
    0
  end
end
