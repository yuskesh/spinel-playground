# examples/doom/core/src/source.rb — the column and span sources as a selector and a base.
#
# GPL-derived, from `examples/doom/lib/doom/render.rb` (`Doom::Renderer`:
# `set_texture_column`, the sky and masked column producers, `draw_planes`,
# `draw_column`, `draw_span`) and `examples/doom/lib/doom/executor.rb`
# (`JobExecutor#exec_masked`), from doomgeneric's `r_draw.c`, `r_segs.c`,
# `r_plane.c` and `r_things.c`. See ../NOTICE.md and ../sources.tsv.
#
# THE ORIGINAL HOLDS A REFERENCE TO A BUFFER -- `@dc_srcbuf`, `@ds_source` -- and
# CORE holds no references. docs/core/doom-source-alias.md settles what replaces
# them: a SELECTOR naming one of the resources the schema already declares, and
# a BASE into it. The values are jobs.rb's, not new ones, plus RES_NONE:
#
#     RES_NONE  -1   nothing selected (the initial state)
#     RES_ATLAS  0   texture column atlas
#     RES_WAD    1   the IWAD bytes (a masked post inside its lump)
#     RES_ZONE   2   a zone window: `@zonewin` on the direct path, a ring slot
#                    for a queued job -- the CONSUMER'S context chooses which
#     RES_FLAT   3   flat atlas
#
# EVERY PRODUCER SETS BOTH, ON EVERY PATH. The original sets `@dc_srcbase` only
# in job mode and `@dc_srcres` only on masked paths, which is harmless there and
# would leave a stale selector here. The producers below take no mode that
# decides whether to write.
#
# A CONSUMER DOES NOT GUESS. It reads only the resources its context can name;
# a selector it cannot read -- RES_NONE included -- answers -1 and draws
# nothing, so the caller reports it. That is a result value, not a new status.
#
# THE SELECTOR AND BASE ARE TWO SCALAR FIELDS, and every scalar field lives in
# the one shared `core_state` buffer. So each definition takes that buffer ONCE
# and the INDICES of the two cells -- the registry's slot numbers -- rather
# than two one-element views of it: an adapter caller has one id for
# core_state, and passing it twice as a mutable participant is what 0007
# refuses.

RES_NONE = -1
RES_ATLAS = 0
RES_WAD = 1
RES_ZONE = 2
RES_FLAT = 3

# The initial state: nothing selected.
def dc_src_none(state, i_res, i_base)
  state[i_res] = RES_NONE
  state[i_base] = 0
  0
end

# A wall or sky column: the texture's window in the atlas. Columns sit at a
# fixed 128-byte stride (`Textures::TEXCOL_STRIDE`), so the window is
# `atlas_base + ((col & widthmask) << 7)`; the sky passes its angle as `col`.
def dc_src_texture_column(state, i_res, i_base, atlas_base, widthmask, col)
  state[i_res] = RES_ATLAS
  state[i_base] = atlas_base + ((col & widthmask) << 7)
  0
end

# A masked post. It is read in place when 128 bytes remain inside the lump;
# otherwise from a zone window -- the ring slot a queued job was given, or the
# direct path's single window at 0.
def dc_src_masked_post(state, i_res, i_base, post_ofs, lump_end, queued, zone_slot)
  if post_ofs + 128 <= lump_end
    state[i_res] = RES_WAD
    state[i_base] = post_ofs
  elsif queued != 0
    state[i_res] = RES_ZONE
    state[i_base] = zone_slot
  else
    state[i_res] = RES_ZONE
    state[i_base] = 0
  end
  0
end

# A span's flat: its 4096-byte face in the flat atlas.
def dc_src_span(state, i_res, i_base, flat_base)
  state[i_res] = RES_FLAT
  state[i_base] = flat_base
  0
end

# `R_DrawColumn` on the direct path, reading through the selector. RES_ZONE here
# is the renderer's own window. Answers 1 drawn, 0 nothing to draw, -1 a
# selector this consumer cannot read.
def dc_draw_column(scr, n_scr, cmap, n_cmap, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin,
                   state, i_res, i_base, x, yl, yh, iscale, texmid, colormap_row,
                   centery, sw, vwx, vwy)
  count = yh - yl
  return 0 if count < 0
  sel = state[i_res]
  return -1 if sel != RES_ATLAS && sel != RES_WAD && sel != RES_ZONE
  base = state[i_base]
  cm = colormap_row * 256
  fracstep = iscale
  frac = core_w32_add(texmid, core_w32_mul(core_w32_sub(yl, centery), fracstep))
  o = (yl + vwy) * sw + x + vwx
  i = 0
  while i <= count
    k = base + ((frac >> 16) & 127)
    b = 0
    if sel == RES_ATLAS
      b = atlas[k]
    elsif sel == RES_WAD
      b = wad[k]
    else
      b = zonewin[k]
    end
    scr[o] = cmap[cm + b]
    o += sw
    frac = core_w32_add(frac, fracstep)
    i += 1
  end
  1
end

# `R_DrawSpan` on the direct path, reading through the selector. The x and y
# fractions are packed into one 32-bit position as the reference does.
def dc_draw_span(scr, n_scr, cmap, n_cmap, flat, n_flat, state, i_res, i_base,
                 y, x1, x2, xfrac, yfrac, xstep, ystep, colormap_row, sw, vwx, vwy)
  return -1 if state[i_res] != RES_FLAT
  base = state[i_base]
  # x in the high half, y in the low (C: ((xfrac << 10) & 0xffff0000) | ((yfrac >> 6) & 0xffff)):
  # bits 6..21 of each, the high half placed by a word multiply (decision 0022)
  position = core_w32_mul((xfrac >> 6) & 0xffff, 65536) | ((yfrac >> 6) & 0xffff)
  step = core_w32_mul((xstep >> 6) & 0xffff, 65536) | ((ystep >> 6) & 0xffff)
  cm = colormap_row * 256
  o = (y + vwy) * sw + x1 + vwx
  count = x2 - x1
  i = 0
  while i <= count
    spot = core_u32_shr(position, 26) | ((position >> 4) & 0x0fc0)
    scr[o] = cmap[cm + flat[base + spot]]
    o += 1
    position = core_w32_add(position, step)
    i += 1
  end
  1
end

# A queued masked job, as the executor runs it. RES_ZONE here is the RING, at the
# job's slot -- the other store for the same selector. A masked job's source is
# only ever the IWAD or the ring.
def dc_draw_masked_job(scr, n_scr, cmap, n_cmap, wad, n_wad, zonebuf, n_zonebuf,
                       srcres, srcbase, x, yl, yh, iscale, texmid, colormap_row,
                       centery, width, vwx, vwy)
  count = yh - yl
  return 0 if count < 0
  return -1 if srcres != RES_WAD && srcres != RES_ZONE
  cm = colormap_row * 256
  fracstep = iscale
  frac = core_w32_add(texmid, core_w32_mul(core_w32_sub(yl, centery), fracstep))
  o = (yl + vwy) * width + x + vwx
  i = 0
  while i <= count
    k = srcbase + ((frac >> 16) & 127)
    b = 0
    if srcres == RES_WAD
      b = wad[k]
    else
      b = zonebuf[k]
    end
    scr[o] = cmap[cm + b]
    o += width
    frac = core_w32_add(frac, fracstep)
    i += 1
  end
  1
end
