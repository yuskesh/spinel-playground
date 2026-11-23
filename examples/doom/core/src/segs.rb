# examples/doom/core/src/segs.rb — the wall seg loop.
#
# GPL-derived, from `examples/doom/lib/doom/render.rb` (`Doom::Renderer`:
# `render_seg_loop`, the wall paths of `draw_column`, `set_texture_column`),
# which reproduces doomgeneric's `r_segs.c` (`R_RenderSegLoop`) and `r_draw.c`
# (`R_DrawColumn`). See ../NOTICE.md and ../sources.tsv.
#
# ONE WALL SEG, COLUMN BY COLUMN, from rw_x to rw_stopx: the plane marks, the
# clip arrays, the masked texture column, and each tier's column. Its caller,
# store_wall_range, is not ported, so the port runs beside the original at each
# call, with the values store_wall_range set loaded from the original.
#
# THE COLUMN DEPENDS ON THE JOB MODE, AS THE ORIGINAL'S DOES. In mode 0 -- the
# playable program's default -- `draw_column` draws the pixels; in modes 1 and 2
# it pushes a wall job (`emit_column`'s phase-0/1 branch; this loop runs only
# inside the BSP walk, where the phase is 0). Both are written out here; the job
# mode is a value Full prepares. The frame lane runs mode 2 and so sees only the
# push; the direct lane is what sees the drawing.
#
# WALLS NEVER FUZZ, BY CONSTRUCTION. `draw_column` also has the fuzz path
# (`draw_fuzz_column`), taken when `@dc_fuzz` is set. `@dc_fuzz` is written in
# three places: false in the constructor, from the sprite's MF_SHADOW flag at the
# top of `draw_vissprite`, and false again before `draw_vissprite` returns --
# and between those two, draw_vissprite calls only `draw_masked_column`, never
# this loop. So the column here has no fuzz branch; that path, and the masked
# one, move with the sprites. The direct lane also counts wall columns drawn
# with `@dc_fuzz` set, and requires none.
#
# THE SOURCE IS A SELECTOR AND A BASE (source.rb): every tier sets RES_ATLAS and
# `atlas_base + ((col & widthmask) << 7)` in both modes, where the original sets
# `@dc_srcbase` only in job mode. The direct column reads through them.
#
# ONE CLOSURE PER OPERATION: the light index, the texture-column producer, the
# direct column and the wall push are copies (dups.tsv), because other entries
# reach the originals.
#
# `trace_column` is not here: it is called only when the renderer traces, which
# no program does (core-migrated.tsv: unreached-in-config:trace).

SL_M16 = 0xffff
SL_SGN16 = 0x8000
SL_HEIGHTBITS = 12
SL_HEIGHTUNIT = 4096
SL_ANGLETOFINESHIFT = 19
# finetangent's count, as catalog.tsv gives it; a buffer's length is not
# available in a helper, so it is named.
SL_FINETANGENT_COUNT = 4096

# `R_RenderSegLoop`. Answers the number of tier columns it drew or pushed.
def dc_render_seg_loop(state, ceilingclip, floorclip, pl_top, pl_bottom, openings, xtoviewangle, finetangent, finesine,
                       scalelight, resscale, tex_widthmask, tex_atlas_base, plw, viewheight, jobmode,
                       scr, cmap, atlas, wad, zonewin, centery, sw, viewwindowx, viewwindowy,
                       wall, sc_kind, sc_idx, cap_wall, cap_sched,
                       i_rw_x, i_rw_stopx, i_topfrac, i_bottomfrac, i_topstep, i_bottomstep,
                       i_pixhigh, i_pixlow, i_pixhighstep, i_pixlowstep, i_rw_scale, i_rw_scalestep,
                       i_markceiling, i_markfloor, i_ceilingplane, i_floorplane, i_segtextured,
                       i_rw_centerangle, i_rw_distance, i_rw_offset, i_walllights,
                       i_midtexture, i_toptexture, i_bottomtexture, i_maskedtexture,
                       i_rw_midtexturemid, i_rw_toptexturemid, i_rw_bottomtexturemid, i_maskedtexturecol,
                       i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap, i_dc_srcofs,
                       i_dc_srcres, i_dc_srcbase, i_nwall, i_nsched)
  columns = 0
  pw = plw[0]
  cy = centery[0]
  width = sw[0]
  vwx = viewwindowx[0]
  vwy = viewwindowy[0]
  jm = jobmode[0]
  while state[i_rw_x] < state[i_rw_stopx]
    x = state[i_rw_x]

    yl = core_w32_sub(core_w32_add(state[i_topfrac], SL_HEIGHTUNIT), 1)
    yl = yl >> SL_HEIGHTBITS
    cc = ceilingclip[x]
    yl = cc + 1 if yl < cc + 1

    if state[i_markceiling] != 0
      top = ceilingclip[x] + 1
      bottom = yl - 1
      bottom = floorclip[x] - 1 if bottom >= floorclip[x]
      if top <= bottom
        b = state[i_ceilingplane] * pw + 1 + x
        pl_top[b] = top
        pl_bottom[b] = bottom
      end
    end

    yh = state[i_bottomfrac] >> SL_HEIGHTBITS
    fc = floorclip[x]
    yh = fc - 1 if yh >= fc

    if state[i_markfloor] != 0
      top = yh + 1
      bottom = floorclip[x] - 1
      top = ceilingclip[x] + 1 if top <= ceilingclip[x]
      if top <= bottom
        b = state[i_floorplane] * pw + 1 + x
        pl_top[b] = top
        pl_bottom[b] = bottom
      end
    end

    texturecolumn = 0
    if state[i_segtextured] != 0
      angle = core_u32_shr(core_w32_add(state[i_rw_centerangle], xtoviewangle[x]), SL_ANGLETOFINESHIFT)
      # angle is SL_FINETANGENT_COUNT, one past the table, when the sum is
      # exactly ANG180; vanilla reads the next table in memory, finesine[0].
      # As lib/doom/render.rb's render_seg_loop does (see its comment).
      ft = angle == SL_FINETANGENT_COUNT ? finesine[0] : finetangent[angle]
      m = core_fixed_mul(ft, state[i_rw_distance])
      texturecolumn = (core_w32_sub(state[i_rw_offset], m)) >> 16
      index = dc_sl_light_index(resscale, state[i_rw_scale])
      state[i_dc_colormap] = scalelight[state[i_walllights] + index]
      state[i_dc_x] = x
      # unsigned 32-bit division, as `dc_iscale = 0xffffffff / rw_scale`
      state[i_dc_iscale] = dc_sl_umax_div(state[i_rw_scale])
    end

    mid_tex = state[i_midtexture]
    if mid_tex != 0
      state[i_dc_yl] = yl
      state[i_dc_yh] = yh
      state[i_dc_texturemid] = state[i_rw_midtexturemid]
      dc_sl_wall_column(state, tex_widthmask, tex_atlas_base, scr, cmap, atlas, wad, zonewin,
                        wall, sc_kind, sc_idx, cap_wall, cap_sched,
                        i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap,
                        i_dc_srcofs, i_dc_srcres, i_dc_srcbase, i_nwall, i_nsched,
                        jm, mid_tex, texturecolumn, cy, width, vwx, vwy)
      columns += 1
      ceilingclip[x] = ((viewheight[0] & SL_M16) ^ SL_SGN16) - SL_SGN16
      floorclip[x] = -1
    else
      top_tex = state[i_toptexture]
      if top_tex != 0
        mid = state[i_pixhigh] >> SL_HEIGHTBITS
        state[i_pixhigh] = core_w32_add(state[i_pixhigh], state[i_pixhighstep])
        mid = floorclip[x] - 1 if mid >= floorclip[x]
        if mid >= yl
          state[i_dc_yl] = yl
          state[i_dc_yh] = mid
          state[i_dc_texturemid] = state[i_rw_toptexturemid]
          dc_sl_wall_column(state, tex_widthmask, tex_atlas_base, scr, cmap, atlas, wad, zonewin,
                            wall, sc_kind, sc_idx, cap_wall, cap_sched,
                            i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap,
                            i_dc_srcofs, i_dc_srcres, i_dc_srcbase, i_nwall, i_nsched,
                            jm, top_tex, texturecolumn, cy, width, vwx, vwy)
          columns += 1
          ceilingclip[x] = ((mid & SL_M16) ^ SL_SGN16) - SL_SGN16
        else
          ceilingclip[x] = (((yl - 1) & SL_M16) ^ SL_SGN16) - SL_SGN16
        end
      elsif state[i_markceiling] != 0
        ceilingclip[x] = (((yl - 1) & SL_M16) ^ SL_SGN16) - SL_SGN16
      end

      bottom_tex = state[i_bottomtexture]
      if bottom_tex != 0
        mid = core_w32_sub(core_w32_add(state[i_pixlow], SL_HEIGHTUNIT), 1)
        mid = mid >> SL_HEIGHTBITS
        state[i_pixlow] = core_w32_add(state[i_pixlow], state[i_pixlowstep])
        mid = ceilingclip[x] + 1 if mid <= ceilingclip[x]
        if mid <= yh
          state[i_dc_yl] = mid
          state[i_dc_yh] = yh
          state[i_dc_texturemid] = state[i_rw_bottomtexturemid]
          dc_sl_wall_column(state, tex_widthmask, tex_atlas_base, scr, cmap, atlas, wad, zonewin,
                            wall, sc_kind, sc_idx, cap_wall, cap_sched,
                            i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap,
                            i_dc_srcofs, i_dc_srcres, i_dc_srcbase, i_nwall, i_nsched,
                            jm, bottom_tex, texturecolumn, cy, width, vwx, vwy)
          columns += 1
          floorclip[x] = ((mid & SL_M16) ^ SL_SGN16) - SL_SGN16
        else
          floorclip[x] = (((yh + 1) & SL_M16) ^ SL_SGN16) - SL_SGN16
        end
      elsif state[i_markfloor] != 0
        floorclip[x] = (((yh + 1) & SL_M16) ^ SL_SGN16) - SL_SGN16
      end

      if state[i_maskedtexture] != 0
        # `maskedtexturecol` is a short[] in C: 16 bits
        openings[state[i_maskedtexturecol] + x] = ((texturecolumn & SL_M16) ^ SL_SGN16) - SL_SGN16
      end
      # the branch's value, so the no-else `if` above is a statement (the
      # kernel types every conditional that ends a branch)
      0
    end

    state[i_rw_scale] = core_w32_add(state[i_rw_scale], state[i_rw_scalestep])
    state[i_topfrac] = core_w32_add(state[i_topfrac], state[i_topstep])
    state[i_bottomfrac] = core_w32_add(state[i_bottomfrac], state[i_bottomstep])
    state[i_rw_x] = x + 1
  end
  columns
end

# One tier's column: `set_texture_column` then `draw_column`'s wall paths. The
# selector and base are set in both modes; mode 0 draws, modes 1 and 2 push.
def dc_sl_wall_column(state, tex_widthmask, tex_atlas_base, scr, cmap, atlas, wad, zonewin,
                      wall, sc_kind, sc_idx, cap_wall, cap_sched,
                      i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap,
                      i_dc_srcofs, i_dc_srcres, i_dc_srcbase, i_nwall, i_nsched,
                      jobmode, tex, col, centery, sw, vwx, vwy)
  state[i_dc_srcofs] = (col & tex_widthmask[tex]) << 7
  dc_sl_src_texture_column(state, i_dc_srcres, i_dc_srcbase, tex_atlas_base[tex], tex_widthmask[tex], col)
  if jobmode != 0
    dc_sl_push_wall(state, wall, sc_kind, sc_idx, cap_wall, cap_sched, i_nwall, i_nsched,
                    state[i_dc_x], state[i_dc_yl], state[i_dc_yh], state[i_dc_iscale],
                    state[i_dc_texturemid], state[i_dc_srcbase], state[i_dc_colormap])
  else
    dc_sl_draw_column(scr, 0, cmap, 0, atlas, 0, wad, 0, zonewin, 0,
                      state, i_dc_srcres, i_dc_srcbase, state[i_dc_x], state[i_dc_yl], state[i_dc_yh],
                      state[i_dc_iscale], state[i_dc_texturemid], state[i_dc_colormap],
                      centery, sw, vwx, vwy)
  end
  0
end

# C's unsigned `0xffffffff / s`, for a positive s, as the i32 pattern of
# the quotient (decision 0022: no i32 holds 0xffffffff). 2**32 - 1 is
# 2 * (2**31 - 1) + 1, so with q, r the quotient and remainder of 2**31 - 1
# by s, the quotient is 2q, plus one when 2r + 1 >= s (2r >= s - 1, written
# without the product), wrapped to 32 bits.
def dc_sl_umax_div(s)
  q = 2147483647 / s
  r = 2147483647 % s
  core_w32_add(core_w32_mul(q, 2), r >= s - 1 - r ? 1 : 0)
end

# copy of dc_light_index (leaves.rb)
def dc_sl_light_index(resscale, scale)
  index = (scale >> RL_LIGHTSCALESHIFT) / resscale[0]
  index >= RL_MAXLIGHTSCALE ? RL_MAXLIGHTSCALE - 1 : index
end

# copy of dc_src_texture_column (source.rb)
def dc_sl_src_texture_column(state, i_res, i_base, atlas_base, widthmask, col)
  state[i_res] = RES_ATLAS
  state[i_base] = atlas_base + ((col & widthmask) << 7)
  0
end

# copy of dc_push_wall (jobs.rb)
def dc_sl_push_wall(state, wall, sc_kind, sc_idx, cap_wall, cap_sched, i_nwall, i_nsched,
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

# copy of dc_draw_column (source.rb)
def dc_sl_draw_column(scr, n_scr, cmap, n_cmap, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin,
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
