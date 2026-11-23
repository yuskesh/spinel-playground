# examples/doom/core/src/planes.rb — a visplane drawn, and the planes cleared.
#
# GPL-derived, from `examples/doom/lib/doom/render.rb` (`Doom::Renderer#draw_planes`'s
# per-plane body and `#clear_planes`), which reproduce doomgeneric's
# `r_plane.c` (`R_DrawPlanes`, `R_ClearPlanes`). See ../NOTICE.md and
# ../sources.tsv.
#
# `dc_draw_planes` IS THE WALK: every visplane from `pl_from` to the
# `lastvisplane` cell. `dc_draw_plane` is one plane -- its source, height, light,
# sentinel columns and every column through `dc_make_spans` (src/planespan.rb)
# -- and answers 1 for a sky plane, which `dc_draw_sky_plane` draws as texture
# columns: for each column with a run, the column's sky angle picks the texture
# column, and the job is pushed into the wall bank as `#emit_column` pushes a
# phase-0/1 column (`push_wall` written out). The original walks from plane 0;
# `pl_from` lets a caller walk from a later plane, and is 0 for the whole walk.
# The column's `@dc_srcbuf` (the texture bytes the mode-0 path draws from) and
# the plane's `@ds_source` are not set: job mode reads neither. The fuzz and
# masked branches of `#emit_column` are not here.
#
# `dc_clear_planes` is the frame's reset: the clip arrays over the view's width,
# the visplane and opening counters, the row cache over the screen's height, and
# the base scales from the view angle through `core_fixed_div` (decision 0022).
#
# Every array arrives as a borrowed buffer and every scalar field as an index
# into `core_state`; the prepared constants -- the visplane stride, the empty
# sentinel, the sky flat's number, the view's width and height and the screen's
# height, the half-width in fixed point -- are one-element buffers.

PL_LIGHTSEGSHIFT = 4
PL_LIGHTLEVELS = 16
PL_MAXLIGHTZ = 128
PL_ANGLETOFINESHIFT = 19
PL_ANGLETOSKYSHIFT = 22
PL_WC_NF = 7
PL_KIND_WALL = 0

# `draw_planes`' body for plane `pl`: 1 if it is the sky and the caller must
# draw it, 0 otherwise.
def dc_draw_plane(state, pl_minx, pl_maxx, pl_picnum, pl_height, pl_lightlevel, pl_top, pl_bottom,
                  spanstart, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                  xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                  plw, plempty, skyflatnum,
                  i_viewz, i_extralight, i_planeheight, i_planezlight, i_curpicnum,
                  i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy, i_nspan, i_nsched, pl, jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
  minx = pl_minx[pl]
  maxx = pl_maxx[pl]
  return 0 if minx > maxx
  # the original sets curpicnum before it tests for the sky
  picnum = pl_picnum[pl]
  state[i_curpicnum] = picnum
  return 1 if picnum == skyflatnum[0]
  ph = pl_height[pl] - state[i_viewz]
  state[i_planeheight] = ph < 0 ? -ph : ph
  light = (pl_lightlevel[pl] >> PL_LIGHTSEGSHIFT) + state[i_extralight]
  light = PL_LIGHTLEVELS - 1 if light >= PL_LIGHTLEVELS
  light = 0 if light < 0
  state[i_planezlight] = light * PL_MAXLIGHTZ
  b = pl * plw[0] + 1
  pl_top[b + maxx + 1] = plempty[0]
  pl_top[b + minx - 1] = plempty[0]
  stop = maxx + 1
  x = minx
  while x <= stop
    dc_make_spans(state, spanstart, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                  xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                  i_planeheight, i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy,
                  i_planezlight, i_curpicnum, i_nspan, i_nsched,
                  x, pl_top[b + x - 1], pl_bottom[b + x - 1], pl_top[b + x], pl_bottom[b + x], jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
    x += 1
  end
  0
end

# `clear_planes`: the frame's clip arrays, counters, row cache and base scales.
def dc_clear_planes(state, floorclip, ceilingclip, cachedheight, finesine, centerxfrac, viewwidth, viewheight, sh,
                    i_viewangle, i_lastvisplane, i_lastopening, i_floorplane, i_ceilingplane,
                    i_basexscale, i_baseyscale)
  w = viewwidth[0]
  i = 0
  while i < w
    floorclip[i] = viewheight[0]
    ceilingclip[i] = -1
    i += 1
  end
  state[i_lastvisplane] = 0
  state[i_lastopening] = 0
  state[i_floorplane] = -1
  state[i_ceilingplane] = -1
  h = sh[0]
  i = 0
  while i < h
    cachedheight[i] = 0
    i += 1
  end
  angle = core_u32_shr(core_w32_sub(state[i_viewangle], 0x40000000), PL_ANGLETOFINESHIFT)
  state[i_basexscale] = core_fixed_div(finesine[angle + 2048], centerxfrac[0])
  state[i_baseyscale] = core_w32_neg(core_fixed_div(finesine[angle], centerxfrac[0]))
  0
end

# `draw_sky_plane` for plane `pl`: each column with a run is a texture column of
# the sky, pushed as a wall job.
def dc_draw_sky_plane(state, pl_minx, pl_maxx, pl_top, pl_bottom, xtoviewangle, tex_widthmask, tex_atlas_base,
                      wall, sc_kind, sc_idx, cap_wall, cap_sched, plw, skytexture, pspriteiscale, skytexturemid,
                      i_viewangle, i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap,
                      i_dc_srcofs, i_dc_srcbase, i_nwall, i_nsched, pl, jobmode, scr, cmap, atlas, wad, zonewin, centery, sw, viewwindowx, viewwindowy, i_dc_srcres)
  tex = skytexture[0]
  b = pl * plw[0] + 1
  x = pl_minx[pl]
  maxx = pl_maxx[pl]
  while x <= maxx
    yl = pl_top[b + x]
    yh = pl_bottom[b + x]
    if yl <= yh
      angle = core_u32_shr(core_w32_add(state[i_viewangle], xtoviewangle[x]), PL_ANGLETOSKYSHIFT)
      state[i_dc_x] = x
      state[i_dc_yl] = yl
      state[i_dc_yh] = yh
      state[i_dc_iscale] = pspriteiscale[0]
      state[i_dc_texturemid] = skytexturemid[0]
      state[i_dc_colormap] = 0
      c = (angle & tex_widthmask[tex]) << 7
      state[i_dc_srcofs] = c
      state[i_dc_srcbase] = tex_atlas_base[tex] + c
      if jobmode[0] == 0
        # job mode 0, Renderer#draw_column's direct path: the column drawn here
        state[i_dc_srcres] = RES_ATLAS
        dc_draw_column(scr, 0, cmap, 0, atlas, 0, wad, 0, zonewin, 0, state, i_dc_srcres, i_dc_srcbase,
                       x, yl, yh, pspriteiscale[0], skytexturemid[0], 0, centery[0], sw[0], viewwindowx[0],
                       viewwindowy[0])
      else
        # `emit_column`'s phase-0/1 branch: `push_wall`, written out
        i = state[i_nwall]
        if i >= cap_wall[0]
          core_fail(:capacity)
        end
        wb = i * PL_WC_NF
        wall[wb] = x
        wall[wb + 1] = yl
        wall[wb + 2] = yh
        wall[wb + 3] = pspriteiscale[0]
        wall[wb + 4] = skytexturemid[0]
        wall[wb + 5] = state[i_dc_srcbase]
        wall[wb + 6] = 0
        state[i_nwall] = i + 1
        sc = state[i_nsched]
        if sc >= cap_sched[0]
          core_fail(:capacity)
        end
        sc_kind[sc] = PL_KIND_WALL
        sc_idx[sc] = i
        state[i_nsched] = sc + 1
      end
    end
    x += 1
  end
  0
end

# `draw_planes`: every visplane from `pl_from` to the lastvisplane cell. Answers
# the number of sky planes it drew.
def dc_draw_planes(state, pl_minx, pl_maxx, pl_picnum, pl_height, pl_lightlevel, pl_top, pl_bottom,
                   spanstart, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                   xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                   plw, plempty, skyflatnum, tex_widthmask, tex_atlas_base, wall, cap_wall, skytexture,
                   pspriteiscale, skytexturemid,
                   i_viewz, i_extralight, i_planeheight, i_planezlight, i_curpicnum,
                   i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy, i_nspan, i_nsched,
                   i_lastvisplane, i_nwall, i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid,
                   i_dc_colormap, i_dc_srcofs, i_dc_srcbase, pl_from, jobmode, scr, cmap, flat, atlas, wad,
                   zonewin, centery, sw, viewwindowx, viewwindowy, i_dc_srcres)
  skies = 0
  pl = pl_from
  while pl < state[i_lastvisplane]
    sky = dc_draw_plane(state, pl_minx, pl_maxx, pl_picnum, pl_height, pl_lightlevel, pl_top, pl_bottom,
                        spanstart, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                        xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                        plw, plempty, skyflatnum,
                        i_viewz, i_extralight, i_planeheight, i_planezlight, i_curpicnum,
                        i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy, i_nspan, i_nsched, pl, jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
    if sky == 1
      dc_draw_sky_plane(state, pl_minx, pl_maxx, pl_top, pl_bottom, xtoviewangle, tex_widthmask, tex_atlas_base,
                        wall, sc_kind, sc_idx, cap_wall, cap_sched, plw, skytexture, pspriteiscale, skytexturemid,
                        i_viewangle, i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap,
                        i_dc_srcofs, i_dc_srcbase, i_nwall, i_nsched, pl, jobmode, scr, cmap, atlas, wad, zonewin, centery, sw, viewwindowx, viewwindowy, i_dc_srcres)
      skies += 1
    end
    pl += 1
  end
  skies
end
