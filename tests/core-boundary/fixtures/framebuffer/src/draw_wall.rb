# Extracted for decision 0007 task 5 from the Full job executor.
#
#   original: examples/doom/lib/doom/executor.rb (Doom::JobExecutor#exec_wall)
#   upstream: DG/r_draw.c:R_DrawColumn, via R009 section 7.2
#
# Every adaptation is listed in this file. The rule is the one the fixed-point
# helpers already follow: the ADAPTED source and the ORIGINAL must agree, and
# here they must agree on EVERY BYTE of the framebuffer, checked under CRuby,
# so an adaptation that changed the meaning is caught rather than argued about.
#
# Adaptation 1: the frame constants and the job fields become parameters.
# The original reads them from ivars (`@width`, `@centery`, `@wall[b + ...]`)
# because the executor holds the whole job bank. A CORE entry takes its scalars
# by declaration, so the caller unpacks one job and passes its seven fields
# plus the five frame constants. Nothing is recomputed: `centery` is passed in
# rather than derived, because the original derives it once in `initialize`.
#
# Adaptation 2: `scr.setbyte(o, v)` becomes `scr[o] = v` and `buf.getbyte(i)`
# becomes `buf[i]`. The original works on a Ruby String because the Full path
# hands the executor the real framebuffer String; a CORE `u8` buffer is the
# same sequence of bytes addressed the same way. Under CRuby the extracted
# source is therefore driven with an Array of integers.
#
#   This is where CRuby and the CORE ABI genuinely part company, and the
#   parting is not hidden: a negative index reads from the end in CRuby and is
#   SPINEL_CORE_BOUNDS here, and a store past the end grows a CRuby Array and
#   is SPINEL_CORE_BOUNDS here. The comparison lane therefore keeps every job
#   inside the screen, and the out-of-range behaviour is checked against the
#   status ABI by the refusal cases instead of against CRuby.
#
# Adaptation 3: `return if count < 0` becomes an if/else over the whole body.
# A modifier `if` has no else, and the checked subset requires both arms. The
# guarded value is 0, which is the status-OK result for a column that draws
# nothing -- the original returns nil there and nothing reads it.
#
# Nothing else moved. The inner loop is the original's, `& M32` and all: the
# masking is what makes `frac >> 16` an unsigned shift of a 16.16 fixed-point
# value, which is the point of R009 section 7.2.

M32 = 0xffffffff

def draw_wall(scr, n_scr, atlas, n_atlas, cmap, n_cmap,
              yl, yh, srcofs, cmapidx, iscale, texmid, x,
              width, viewwindowx, viewwindowy, centery)
  count = yh - yl
  if count < 0
    0
  else
    cm = cmapidx * 256
    fracstep = iscale & M32
    frac = (texmid + (yl - centery) * fracstep) & M32
    o = (yl + viewwindowy) * width + x + viewwindowx
    i2 = 0
    while i2 <= count
      scr[o] = cmap[cm + atlas[srcofs + ((frac >> 16) & 127)]]
      o += width
      frac = (frac + fracstep) & M32
      i2 += 1
    end
    0
  end
end
