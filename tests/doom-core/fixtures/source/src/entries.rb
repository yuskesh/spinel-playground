# Entry wrappers for the source port (examples/doom/core/src/source.rb and
# zone.rb): a boundary declares each buffer's count, and the port's definitions
# take borrowed buffers. The producers answer 0; what they produce is in their
# cells. The consumers answer what the port answers: 1 drawn, 0 nothing to
# draw, -1 a selector this consumer cannot read.
#
# Every scalar field arrives as `state` -- the one core_state buffer -- and the
# index of its cell, never as a view of its own.
def dc_sp_col(scr, n_scr, cmap, n_cmap, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin,
              state, n_state, i_res, i_base, x, yl, yh, iscale, texmid, colormap_row,
              centery, sw, vwx, vwy)
  dc_sp_draw_column(scr, n_scr, cmap, n_cmap, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin,
                    state, i_res, i_base, x, yl, yh, iscale, texmid, colormap_row, centery, sw, vwx, vwy)
end

# THE COLUMN ENTRY DRAWS THROUGH ITS OWN COPY of source.rb's dc_draw_column.
# Since job mode 0, planes.rb's dc_draw_sky_plane calls dc_draw_column too, so
# the dplanes entry's closure holds it, and the kernel admits no call into an
# entry's closure from outside it (unaccounted-ingress): dc_sp_col calling the
# original refused dplanes, and dc_draw_sky_plane calling it refused col. The
# copy is listed in ../dups.tsv, and tests/doom-core/dup-check.rb holds it
# identical to the original, modulo the name. GPL-derived, as the original:
# see examples/doom/core/NOTICE.md (src/source.rb) and examples/doom/LICENSE.
def dc_sp_draw_column(scr, n_scr, cmap, n_cmap, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin,
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

def dc_sp_span(scr, n_scr, cmap, n_cmap, flat, n_flat, state, n_state, i_res, i_base,
               y, x1, x2, xfrac, yfrac, xstep, ystep, colormap_row, sw, vwx, vwy)
  dc_draw_span(scr, n_scr, cmap, n_cmap, flat, n_flat, state, i_res, i_base,
               y, x1, x2, xfrac, yfrac, xstep, ystep, colormap_row, sw, vwx, vwy)
end

def dc_sp_mjob(scr, n_scr, cmap, n_cmap, wad, n_wad, zonebuf, n_zonebuf,
               srcres, srcbase, x, yl, yh, iscale, texmid, colormap_row, centery, width, vwx, vwy)
  dc_draw_masked_job(scr, n_scr, cmap, n_cmap, wad, n_wad, zonebuf, n_zonebuf,
                     srcres, srcbase, x, yl, yh, iscale, texmid, colormap_row, centery, width, vwx, vwy)
end

def dc_sp_none(state, n_state, i_res, i_base)
  dc_src_none(state, i_res, i_base)
end

def dc_sp_tex(state, n_state, i_res, i_base, atlas_base, widthmask, col)
  dc_src_texture_column(state, i_res, i_base, atlas_base, widthmask, col)
end

def dc_sp_mask(state, n_state, i_res, i_base, post_ofs, lump_end, queued, zone_slot)
  dc_src_masked_post(state, i_res, i_base, post_ofs, lump_end, queued, zone_slot)
end

def dc_sp_flat(state, n_state, i_res, i_base, flat_base)
  dc_src_span(state, i_res, i_base, flat_base)
end

# The zone window producer: the lump directory and the IWAD bytes in, the window
# written into `out` at `base`.
def dc_sp_zone(wad, n_wad, lump_pos, n_lump_pos, lump_size, n_lump_size, next_lump, n_next_lump,
               out, n_out, lumpnum, off, base)
  dc_zone_window_into(wad, lump_pos, lump_size, next_lump, out, lumpnum, off, base)
end

# A ring slot, or CAPACITY.
def dc_sp_zalloc(state, n_state, zone_slots, n_zone_slots, i_nzone)
  dc_alloc_zone_window(state, i_nzone, zone_slots)
end

# Jobs#reset.
def dc_sp_jreset(state, n_state, zero_slots, n_zero_slots, i_fuzz_suffix)
  dc_jobs_reset(state, zero_slots, n_zero_slots, i_fuzz_suffix)
end

# JobExecutor#run over the frame's banks: the schedule's length from its
# core_state cell, the frame constants from their one-element fields. Answers
# the number of fuzz columns drawn.
def dc_sp_exec(scr, n_scr, cmap, n_cmap, atlas, n_atlas, flat, n_flat, wad, n_wad, zonebuf, n_zonebuf,
               fuzzoffset, n_fuzzoffset, wall, n_wall, span, n_span, masked, n_masked,
               sc_kind, n_sc_kind, sc_idx, n_sc_idx, state, n_state,
               width, n_width, centery, n_centery, vwx, n_vwx, vwy, n_vwy, i_nsched)
  dc_exec_run(scr, cmap, atlas, flat, wad, zonebuf, fuzzoffset, wall, span, masked,
              sc_kind, sc_idx, state[i_nsched], width[0], centery[0], vwx[0], vwy[0])
end

# The pushes (examples/doom/core/src/jobs.rb): state, the bank, the schedule and
# the two capacities, then the two counters' indices and the record's fields.
def dc_sp_pwall(state, n_state, wall, n_wall, sc_kind, n_sc_kind, sc_idx, n_sc_idx, cap_wall,
                n_cap_wall, cap_sched, n_cap_sched, i_nwall, i_nsched, x, yl, yh, iscale, texmid,
                srcofs, cmap)
  dc_push_wall(state, wall, sc_kind, sc_idx, cap_wall, cap_sched, i_nwall, i_nsched, x, yl, yh,
               iscale, texmid, srcofs, cmap)
end

def dc_sp_pspan(state, n_state, span, n_span, sc_kind, n_sc_kind, sc_idx, n_sc_idx, cap_span,
                n_cap_span, cap_sched, n_cap_sched, i_nspan, i_nsched, y, x1, x2, position, step,
                srcofs, cmap)
  dc_push_span(state, span, sc_kind, sc_idx, cap_span, cap_sched, i_nspan, i_nsched, y, x1, x2,
               position, step, srcofs, cmap)
end

def dc_sp_pmask(state, n_state, masked, n_masked, sc_kind, n_sc_kind, sc_idx, n_sc_idx, cap_masked,
                n_cap_masked, cap_sched, n_cap_sched, i_nmasked, i_nsched, x, yl, yh, iscale,
                texmid, srcres, srcofs, cmap, fuzz)
  dc_push_masked(state, masked, sc_kind, sc_idx, cap_masked, cap_sched, i_nmasked, i_nsched, x, yl,
                 yh, iscale, texmid, srcres, srcofs, cmap, fuzz)
end

def dc_sp_ph1(state, n_state, i_nwall, i_wall_phase0_n)
  dc_mark_phase1(state, i_nwall, i_wall_phase0_n)
end

def dc_sp_ph3(state, n_state, i_nmasked, i_masked_phase2_n)
  dc_mark_phase3(state, i_nmasked, i_masked_phase2_n)
end

# The per-frame interval tables and statistics (examples/doom/core/src/checks.rb):
# state, the bank, the tables and the screen dimension, then the counters' indices.
def dc_sp_cdis(state, n_state, wall, n_wall, xcount, n_xcount, xyl, n_xyl, xyh, n_xyh, width,
               n_width, lo, i_hi, i_max_k, i_overlaps)
  dc_check_disjoint(state, wall, xcount, xyl, xyh, width, lo, i_hi, i_max_k, i_overlaps)
end

def dc_sp_cspan(state, n_state, span, n_span, ycount, n_ycount, yx1, n_yx1, yx2, n_yx2, height,
                n_height, i_nspan, i_span_max_kx, i_span_overlaps)
  dc_check_span_disjoint(state, span, ycount, yx1, yx2, height, i_nspan, i_span_max_kx,
                         i_span_overlaps)
end

def dc_sp_cmask(state, n_state, masked, n_masked, mcount, n_mcount, mlo, n_mlo, mhi, n_mhi, mseq,
                n_mseq, mfz, n_mfz, width, n_width, i_nmasked, i_fuzz_n, i_masked_max_kx,
                i_fuzz_max_kx)
  dc_check_masked_k(state, masked, mcount, mlo, mhi, mseq, mfz, width, i_nmasked, i_fuzz_n,
                    i_masked_max_kx, i_fuzz_max_kx)
end

def dc_sp_call(state, n_state, wall, n_wall, xcount, n_xcount, xyl, n_xyl, xyh, n_xyh, width,
               n_width, i_nwall, i_wall_all_max_k, i_wall_all_overlaps)
  dc_check_wall_all(state, wall, xcount, xyl, xyh, width, i_nwall, i_wall_all_max_k,
                    i_wall_all_overlaps)
end

# The planes' walk and the planes' clear (examples/doom/core/src/planes.rb, with
# planespan.rb's make_spans): the arrays and prepared constants, then the cells' indices.
def dc_sp_dplanes(state, n_state, pl_minx, n_pl_minx, pl_maxx, n_pl_maxx, pl_picnum, n_pl_picnum,
                  pl_height, n_pl_height, pl_lightlevel, n_pl_lightlevel, pl_top, n_pl_top,
                  pl_bottom, n_pl_bottom, spanstart, n_spanstart, cachedheight, n_cachedheight,
                  cacheddistance, n_cacheddistance, cachedxstep, n_cachedxstep, cachedystep,
                  n_cachedystep, yslope, n_yslope, distscale, n_distscale, xtoviewangle,
                  n_xtoviewangle, finesine, n_finesine, zlight, n_zlight, flattranslation,
                  n_flattranslation, span, n_span, sc_kind, n_sc_kind, sc_idx, n_sc_idx, cap_span,
                  n_cap_span, cap_sched, n_cap_sched, plw, n_plw, plempty, n_plempty, skyflatnum,
                  n_skyflatnum, tex_widthmask, n_tex_widthmask, tex_atlas_base, n_tex_atlas_base,
                  wall, n_wall, cap_wall, n_cap_wall, skytexture, n_skytexture, pspriteiscale,
                  n_pspriteiscale, skytexturemid, n_skytexturemid, jobmode, n_jobmode, scr, n_scr, cmap,
                  n_cmap, flat, n_flat, atlas, n_atlas, wad, n_wad, zonewin, n_zonewin, centery, n_centery,
                  sw, n_sw, viewwindowx, n_viewwindowx, viewwindowy, n_viewwindowy, i_viewz, i_extralight,
                  i_planeheight, i_planezlight, i_curpicnum, i_basexscale, i_baseyscale,
                  i_viewangle, i_viewx, i_viewy, i_nspan, i_nsched, i_lastvisplane, i_nwall, i_dc_x,
                  i_dc_yl, i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap, i_dc_srcofs,
                  i_dc_srcbase, i_dc_srcres, pl_from)
  dc_draw_planes(state, pl_minx, pl_maxx, pl_picnum, pl_height, pl_lightlevel, pl_top, pl_bottom,
                 spanstart, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope,
                 distscale, xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx,
                 cap_span, cap_sched, plw, plempty, skyflatnum, tex_widthmask, tex_atlas_base, wall,
                 cap_wall, skytexture, pspriteiscale, skytexturemid, i_viewz, i_extralight,
                 i_planeheight, i_planezlight, i_curpicnum, i_basexscale, i_baseyscale, i_viewangle,
                 i_viewx, i_viewy, i_nspan, i_nsched, i_lastvisplane, i_nwall, i_dc_x, i_dc_yl,
                 i_dc_yh, i_dc_iscale, i_dc_texturemid, i_dc_colormap, i_dc_srcofs, i_dc_srcbase,
                 pl_from, jobmode, scr, cmap, flat, atlas, wad, zonewin, centery, sw, viewwindowx, viewwindowy,
                 i_dc_srcres)
end

def dc_sp_cplanes(state, n_state, floorclip, n_floorclip, ceilingclip, n_ceilingclip, cachedheight,
                  n_cachedheight, finesine, n_finesine, centerxfrac, n_centerxfrac, viewwidth,
                  n_viewwidth, viewheight, n_viewheight, sh, n_sh, i_viewangle, i_lastvisplane,
                  i_lastopening, i_floorplane, i_ceilingplane, i_basexscale, i_baseyscale)
  dc_clear_planes(state, floorclip, ceilingclip, cachedheight, finesine, centerxfrac, viewwidth,
                  viewheight, sh, i_viewangle, i_lastvisplane, i_lastopening, i_floorplane,
                  i_ceilingplane, i_basexscale, i_baseyscale)
end

# THE STATUS BAR (examples/doom/core/src/statusbar.rb), ONE ENTRY. It is one
# entry rather than one per primitive because an entry's selected closure must
# be disjoint from every other entry's: dc_i16, dc_i32 and dc_draw_patch are
# shared by the bar's parts, so reaching them separately would be an ingress
# into a closure from outside it. Drawing the bar is one operation, so it is one
# closure.
#
# ITS PARAMETERS ARE THE MANIFEST'S FIELDS. The widget memory examples/doom/core/
# state.tsv declares as scalars (firsttime, old_armsbg, old_face) and the game's
# scalars the bar reads (faceindex, notdeathmatch) are cells of `state`, named
# by index; the arrays and the prepared one-element resources are buffers of
# their own. fields.tsv names each one. health, armorpoints, ammokind and the
# ammo, maxammo and weaponowned buffers are the caller's arguments -- the
# hand-off at the call site, which no resident field backs.
def dc_sp_sbdraw(screen, n_screen, backing, n_backing, wad, n_wad, lump_pos, n_lump_pos,
                 state, n_state, old_arms, n_old_arms, old_keybox, n_old_keybox, keyboxes, n_keyboxes,
                 tallnum, n_tallnum, shortnum, n_shortnum, armsgray, n_armsgray,
                 faces, n_faces, keys, n_keys,
                 tallw, n_tallw, shortw, n_shortw, sbar, n_sbar, tallpercent, n_tallpercent, armsbg, n_armsbg,
                 ammo, n_ammo, maxammo, n_maxammo, weaponowned, n_weaponowned,
                 i_firsttime, i_old_armsbg, i_old_face, i_faceindex, i_notdeathmatch,
                 health, armorpoints, ammokind)
  dc_draw_statusbar(screen, backing, wad, lump_pos, state,
                    old_arms, old_keybox, keyboxes,
                    tallnum, shortnum, armsgray, faces, keys,
                    tallw, shortw, sbar, tallpercent, armsbg,
                    ammo, maxammo, weaponowned,
                    i_firsttime, i_old_armsbg, i_old_face, i_faceindex, i_notdeathmatch,
                    health, armorpoints, ammokind)
end

# THE HUD'S MESSAGE LINE (examples/doom/core/src/hud.rb), its own entry. Its
# closure is disjoint from the status bar's because it carries its own copies of
# the byte readers rather than calling dc_i16 and dc_i32; dup-check.rb holds the
# copies identical to the originals.
def dc_sp_hudraw(screen, n_screen, wad, n_wad, lump_pos, n_lump_pos, font_lump, n_font_lump,
                 text, n_text, text_ofs, n_text_ofs, sw, n_sw, scale, n_scale, state, n_state,
                 i_message, i_message_on)
  dc_draw_hud(screen, wad, lump_pos, font_lump, text, text_ofs, sw, scale, state, i_message, i_message_on)
end

# THE RENDERER'S LEAVES (examples/doom/core/src/leaves.rb), one entry per
# operation, each closure its own: point_to_angle with the slope_div it alone
# calls, the two fixed_div and the two clear_plane_top copies each in the one
# closure that uses it.
def dc_sp_pangle(state, n_state, tantoangle, n_tantoangle, i_viewx, i_viewy, px, py)
  dc_point_to_angle(state, tantoangle, i_viewx, i_viewy, px, py)
end

def dc_sp_pdist(state, n_state, tantoangle, n_tantoangle, finesine, n_finesine, i_viewx, i_viewy,
                px, py)
  dc_point_to_dist(state, tantoangle, finesine, i_viewx, i_viewy, px, py)
end

def dc_sp_sgscale(state, n_state, finesine, n_finesine, projection, n_projection, i_viewangle,
                  i_rw_normalangle, i_rw_distance, visangle)
  dc_scale_from_global_angle(state, finesine, projection, i_viewangle, i_rw_normalangle,
                             i_rw_distance, visangle)
end

def dc_sp_lindex(resscale, n_resscale, scale)
  dc_light_index(resscale, scale)
end

def dc_sp_absang(u)
  dc_abs_angle(u)
end

def dc_sp_clipv(openings, n_openings, viewheight, n_viewheight, kind, base, x)
  dc_clip_value(openings, viewheight, kind, base, x)
end

def dc_sp_segside(vertex_x, n_vertex_x, vertex_y, n_vertex_y, seg_v1, n_seg_v1, seg_v2, n_seg_v2, x,
                  y, seg)
  dc_point_on_seg_side(vertex_x, vertex_y, seg_v1, seg_v2, x, y, seg)
end

def dc_sp_fplane(state, n_state, pl_height, n_pl_height, pl_picnum, n_pl_picnum, pl_lightlevel,
                 n_pl_lightlevel, pl_minx, n_pl_minx, pl_maxx, n_pl_maxx, pl_top, n_pl_top,
                 skyflatnum, n_skyflatnum, sw, n_sw, plw, n_plw, plempty, n_plempty, i_lastvisplane,
                 height, picnum, lightlevel)
  dc_find_plane(state, pl_height, pl_picnum, pl_lightlevel, pl_minx, pl_maxx, pl_top, skyflatnum,
                sw, plw, plempty, i_lastvisplane, height, picnum, lightlevel)
end

def dc_sp_chplane(state, n_state, pl_height, n_pl_height, pl_picnum, n_pl_picnum, pl_lightlevel,
                  n_pl_lightlevel, pl_minx, n_pl_minx, pl_maxx, n_pl_maxx, pl_top, n_pl_top, plw,
                  n_plw, plempty, n_plempty, i_lastvisplane, pl, start, stop)
  dc_check_plane(state, pl_height, pl_picnum, pl_lightlevel, pl_minx, pl_maxx, pl_top, plw, plempty,
                 i_lastvisplane, pl, start, stop)
end

def dc_sp_ssclear(state, n_state, ss_first, n_ss_first, ss_last, n_ss_last, viewwidth, n_viewwidth,
                  i_newend)
  dc_clear_clip_segs(state, ss_first, ss_last, viewwidth, i_newend)
end

def dc_sp_crunch(state, n_state, ss_first, n_ss_first, ss_last, n_ss_last, i_newend, start, nx)
  dc_crunch(state, ss_first, ss_last, i_newend, start, nx)
end

def dc_sp_chkbbox(state, n_state, node_bbox, n_node_bbox, tantoangle, n_tantoangle, clipangle,
                  n_clipangle, two_clipangle, n_two_clipangle, viewangletox, n_viewangletox,
                  ss_first, n_ss_first, ss_last, n_ss_last, i_viewx, i_viewy, i_viewangle, n, child)
  dc_check_bbox(state, node_bbox, tantoangle, clipangle, two_clipangle, viewangletox, ss_first,
                ss_last, i_viewx, i_viewy, i_viewangle, n, child)
end

def dc_sp_vssort(state, n_state, vs_scale, n_vs_scale, vs_taken, n_vs_taken, vs_sorted, n_vs_sorted,
                 i_vis_n)
  dc_sort_vissprites(state, vs_scale, vs_taken, vs_sorted, i_vis_n)
end

def dc_sp_addspr(state, n_state, sector_validcount, n_sector_validcount, sector_lightlevel,
                 n_sector_lightlevel, sector_head, n_sector_head, thing_next, n_thing_next, mobj_x,
                 n_mobj_x, mobj_y, n_mobj_y, mobj_z, n_mobj_z, mobj_angle, n_mobj_angle, mobj_frame,
                 n_mobj_frame, mobj_sprite, n_mobj_sprite, mobj_flags, n_mobj_flags, numframes,
                 n_numframes, rotate, n_rotate, framebase, n_framebase, sprlump, n_sprlump, sprflip,
                 n_sprflip, spriteoffset, n_spriteoffset, spritewidth, n_spritewidth,
                 spritetopoffset, n_spritetopoffset, tantoangle, n_tantoangle, projection,
                 n_projection, centerxfrac, n_centerxfrac, viewwidth, n_viewwidth, scalelight,
                 n_scalelight, resscale, n_resscale, vs_mobjflags, n_vs_mobjflags, vs_scale,
                 n_vs_scale, vs_gx, n_vs_gx, vs_gy, n_vs_gy, vs_gz, n_vs_gz, vs_gzt, n_vs_gzt,
                 vs_texturemid, n_vs_texturemid, vs_x1, n_vs_x1, vs_x2, n_vs_x2, vs_startfrac,
                 n_vs_startfrac, vs_xiscale, n_vs_xiscale, vs_patch, n_vs_patch, vs_cmap, n_vs_cmap,
                 i_validcount, i_extralight, i_viewx, i_viewy, i_viewz, i_viewcos, i_viewsin,
                 i_spritelights, i_vis_n, sec)
  dc_add_sprites(state, sector_validcount, sector_lightlevel, sector_head, thing_next, mobj_x,
                 mobj_y, mobj_z, mobj_angle, mobj_frame, mobj_sprite, mobj_flags, numframes, rotate,
                 framebase, sprlump, sprflip, spriteoffset, spritewidth, spritetopoffset,
                 tantoangle, projection, centerxfrac, viewwidth, scalelight, resscale, vs_mobjflags,
                 vs_scale, vs_gx, vs_gy, vs_gz, vs_gzt, vs_texturemid, vs_x1, vs_x2, vs_startfrac,
                 vs_xiscale, vs_patch, vs_cmap, i_validcount, i_extralight, i_viewx, i_viewy,
                 i_viewz, i_viewcos, i_viewsin, i_spritelights, i_vis_n, sec)
end

def dc_sp_segloop(state, n_state, ceilingclip, n_ceilingclip, floorclip, n_floorclip, pl_top,
                  n_pl_top, pl_bottom, n_pl_bottom, openings, n_openings, xtoviewangle,
                  n_xtoviewangle, finetangent, n_finetangent, finesine, n_finesine, scalelight,
                  n_scalelight, resscale, n_resscale, tex_widthmask, n_tex_widthmask,
                  tex_atlas_base, n_tex_atlas_base, plw, n_plw, viewheight, n_viewheight, jobmode,
                  n_jobmode, scr, n_scr, cmap, n_cmap,
                  atlas, n_atlas, wad, n_wad, zonewin, n_zonewin, centery, n_centery, sw, n_sw,
                  viewwindowx, n_viewwindowx, viewwindowy, n_viewwindowy, wall, n_wall, sc_kind,
                  n_sc_kind, sc_idx, n_sc_idx, cap_wall, n_cap_wall, cap_sched, n_cap_sched, i_rw_x,
                  i_rw_stopx, i_topfrac, i_bottomfrac, i_topstep, i_bottomstep, i_pixhigh, i_pixlow,
                  i_pixhighstep, i_pixlowstep, i_rw_scale, i_rw_scalestep, i_markceiling,
                  i_markfloor, i_ceilingplane, i_floorplane, i_segtextured, i_rw_centerangle,
                  i_rw_distance, i_rw_offset, i_walllights, i_midtexture, i_toptexture,
                  i_bottomtexture, i_maskedtexture, i_rw_midtexturemid, i_rw_toptexturemid,
                  i_rw_bottomtexturemid, i_maskedtexturecol, i_dc_x, i_dc_yl, i_dc_yh, i_dc_iscale,
                  i_dc_texturemid, i_dc_colormap, i_dc_srcofs, i_dc_srcres, i_dc_srcbase, i_nwall,
                  i_nsched)
  dc_render_seg_loop(state, ceilingclip, floorclip, pl_top, pl_bottom, openings, xtoviewangle,
                     finetangent, finesine, scalelight, resscale, tex_widthmask, tex_atlas_base,
                     plw, viewheight, jobmode, scr, cmap, atlas, wad, zonewin, centery, sw,
                     viewwindowx, viewwindowy, wall, sc_kind, sc_idx, cap_wall, cap_sched, i_rw_x,
                     i_rw_stopx, i_topfrac, i_bottomfrac, i_topstep, i_bottomstep, i_pixhigh, i_pixlow,
                     i_pixhighstep, i_pixlowstep, i_rw_scale, i_rw_scalestep, i_markceiling,
                     i_markfloor, i_ceilingplane, i_floorplane, i_segtextured, i_rw_centerangle,
                     i_rw_distance, i_rw_offset, i_walllights, i_midtexture, i_toptexture,
                     i_bottomtexture, i_maskedtexture, i_rw_midtexturemid, i_rw_toptexturemid,
                     i_rw_bottomtexturemid, i_maskedtexturecol, i_dc_x, i_dc_yl, i_dc_yh,
                     i_dc_iscale, i_dc_texturemid, i_dc_colormap, i_dc_srcofs, i_dc_srcres,
                     i_dc_srcbase, i_nwall, i_nsched)
end

# STEPALL BEGIN -- generated by tests/doom-core/stepall.rb, do not edit
def dc_sp_stepall(state, n_state, gx, n_gx, args, n_args, activeplats, n_activeplats, anim_basepic, n_anim_basepic, anim_istexture, n_anim_istexture, anim_numpics, n_anim_numpics, anim_speed, n_anim_speed, blocklinks, n_blocklinks, blockmap, n_blockmap, blockmap_off, n_blockmap_off, bmapheight, n_bmapheight, bmaporgx, n_bmaporgx, bmaporgy, n_bmaporgy, bmapwidth, n_bmapwidth, button_line, n_button_line, button_texture, n_button_texture, button_timer, n_button_timer, button_where, n_button_where, dr_direction, n_dr_direction, dr_sector, n_dr_sector, dr_speed, n_dr_speed, dr_th, n_dr_th, dr_topcountdown, n_dr_topcountdown, dr_topheight, n_dr_topheight, dr_topwait, n_dr_topwait, dr_type, n_dr_type, ff_count, n_ff_count, ff_maxlight, n_ff_maxlight, ff_minlight, n_ff_minlight, ff_sector, n_ff_sector, finesine, n_finesine, fl_crush, n_fl_crush, fl_dest, n_fl_dest, fl_direction, n_fl_direction, fl_sector, n_fl_sector, fl_speed, n_fl_speed, fl_th, n_fl_th, fl_type, n_fl_type, flattranslation, n_flattranslation, gl_direction, n_gl_direction, gl_maxlight, n_gl_maxlight, gl_minlight, n_gl_minlight, gl_sector, n_gl_sector, ic_frac, n_ic_frac, ic_isaline, n_ic_isaline, ic_thing, n_ic_thing, info_activesound, n_info_activesound, info_damage, n_info_damage, info_deathsound, n_info_deathsound, info_deathstate, n_info_deathstate, info_flags, n_info_flags, info_height, n_info_height, info_mass, n_info_mass, info_meleestate, n_info_meleestate, info_missilestate, n_info_missilestate, info_painchance, n_info_painchance, info_painstate, n_info_painstate, info_radius, n_info_radius, info_reactiontime, n_info_reactiontime, info_seesound, n_info_seesound, info_seestate, n_info_seestate, info_spawnhealth, n_info_spawnhealth, info_spawnstate, n_info_spawnstate, info_speed, n_info_speed, info_xdeathstate, n_info_xdeathstate, kn_caps, n_kn_caps, lf_count, n_lf_count, lf_maxlight, n_lf_maxlight, lf_maxtime, n_lf_maxtime, lf_minlight, n_lf_minlight, lf_mintime, n_lf_mintime, lf_sector, n_lf_sector, line_backsector, n_line_backsector, line_bbox_bottom, n_line_bbox_bottom, line_bbox_left, n_line_bbox_left, line_bbox_right, n_line_bbox_right, line_bbox_top, n_line_bbox_top, line_dx, n_line_dx, line_dy, n_line_dy, line_flags, n_line_flags, line_frontsector, n_line_frontsector, line_side0, n_line_side0, line_side1, n_line_side1, line_slopetype, n_line_slopetype, line_special, n_line_special, line_tagno, n_line_tagno, line_v1, n_line_v1, line_v2, n_line_v2, line_validcount, n_line_validcount, linespecials, n_linespecials, mobj_angle, n_mobj_angle, mobj_bnext, n_mobj_bnext, mobj_bprev, n_mobj_bprev, mobj_ceilingz, n_mobj_ceilingz, mobj_flags, n_mobj_flags, mobj_floorz, n_mobj_floorz, mobj_frame, n_mobj_frame, mobj_health, n_mobj_health, mobj_height, n_mobj_height, mobj_lastlook, n_mobj_lastlook, mobj_momx, n_mobj_momx, mobj_momy, n_mobj_momy, mobj_momz, n_mobj_momz, mobj_movecount, n_mobj_movecount, mobj_movedir, n_mobj_movedir, mobj_player, n_mobj_player, mobj_radius, n_mobj_radius, mobj_reactiontime, n_mobj_reactiontime, mobj_sector, n_mobj_sector, mobj_sp_options, n_mobj_sp_options, mobj_sp_type, n_mobj_sp_type, mobj_sprite, n_mobj_sprite, mobj_state, n_mobj_state, mobj_subsector, n_mobj_subsector, mobj_target, n_mobj_target, mobj_th, n_mobj_th, mobj_threshold, n_mobj_threshold, mobj_tics, n_mobj_tics, mobj_tracer, n_mobj_tracer, mobj_type, n_mobj_type, mobj_x, n_mobj_x, mobj_y, n_mobj_y, mobj_z, n_mobj_z, node_child0, n_node_child0, node_child1, n_node_child1, node_dx, n_node_dx, node_dy, n_node_dy, node_x, n_node_x, node_y, n_node_y, num_anims, n_num_anims, num_nodes, n_num_nodes, num_sectors, n_num_sectors, numlinespecials, n_numlinespecials, pl_ammo, n_pl_ammo, pl_cards, n_pl_cards, pl_count, n_pl_count, pl_crush, n_pl_crush, pl_high, n_pl_high, pl_low, n_pl_low, pl_maxammo, n_pl_maxammo, pl_powers, n_pl_powers, pl_sector, n_pl_sector, pl_speed, n_pl_speed, pl_status, n_pl_status, pl_tag, n_pl_tag, pl_th, n_pl_th, pl_type, n_pl_type, pl_wait, n_pl_wait, pl_weaponowned, n_pl_weaponowned, player_mo, n_player_mo, psp_state, n_psp_state, psp_sx, n_psp_sx, psp_sy, n_psp_sy, psp_tics, n_psp_tics, reject, n_reject, sector_blockbox, n_sector_blockbox, sector_ceilingheight, n_sector_ceilingheight, sector_ceilingpic, n_sector_ceilingpic, sector_floorheight, n_sector_floorheight, sector_floorpic, n_sector_floorpic, sector_head, n_sector_head, sector_lightlevel, n_sector_lightlevel, sector_linecount, n_sector_linecount, sector_lineofs, n_sector_lineofs, sector_lines, n_sector_lines, sector_soundtarget, n_sector_soundtarget, sector_soundtraversed, n_sector_soundtraversed, sector_special, n_sector_special, sector_specialdata, n_sector_specialdata, sector_tagno, n_sector_tagno, sector_validcount, n_sector_validcount, seg_backsector, n_seg_backsector, seg_frontsector, n_seg_frontsector, seg_linedef, n_seg_linedef, side_bottomtexture, n_side_bottomtexture, side_midtexture, n_side_midtexture, side_sector, n_side_sector, side_textureoffset, n_side_textureoffset, side_toptexture, n_side_toptexture, sight_stack, n_sight_stack, skill, n_skill, skyflatnum, n_skyflatnum, sound_stack, n_sound_stack, spechit, n_spechit, ss_firstline, n_ss_firstline, ss_numlines, n_ss_numlines, ss_sector, n_ss_sector, st_brighttime, n_st_brighttime, st_count, n_st_count, st_darktime, n_st_darktime, st_maxlight, n_st_maxlight, st_minlight, n_st_minlight, st_sector, n_st_sector, state_action, n_state_action, state_frame, n_state_frame, state_misc1, n_state_misc1, state_misc2, n_state_misc2, state_nextstate, n_state_nextstate, state_sprite, n_state_sprite, state_tics, n_state_tics, switchlist, n_switchlist, tantoangle, n_tantoangle, texturetranslation, n_texturetranslation, th_data, n_th_data, th_func, n_th_func, th_next, n_th_next, th_prev, n_th_prev, thing_next, n_thing_next, thing_prev, n_thing_prev, vertex_x, n_vertex_x, vertex_y, n_vertex_y, weapon_ammo, n_weapon_ammo, weapon_atkstate, n_weapon_atkstate, weapon_downstate, n_weapon_downstate, weapon_flashstate, n_weapon_flashstate, weapon_readystate, n_weapon_readystate, weapon_upstate, n_weapon_upstate, ks, n_ks, keyboxes, n_keyboxes, cards, n_cards, oldweaponsowned, n_oldweaponsowned, weaponowned, n_weaponowned)
  acc = 0
  acc += dc_st_m_random(state, gx)
  acc += dc_st_hud_ticker(state, gx, args[0])
  acc += dc_st_g_ticker(activeplats, anim_basepic, anim_istexture, anim_numpics, anim_speed, blocklinks, blockmap, blockmap_off, bmapheight, bmaporgx, bmaporgy, bmapwidth, button_line, button_texture, button_timer, button_where, dr_direction, dr_sector, dr_speed, dr_th, dr_topcountdown, dr_topheight, dr_topwait, dr_type, ff_count, ff_maxlight, ff_minlight, ff_sector, finesine, fl_crush, fl_dest, fl_direction, fl_sector, fl_speed, fl_th, fl_type, flattranslation, gl_direction, gl_maxlight, gl_minlight, gl_sector, gx, ic_frac, ic_isaline, ic_thing, info_activesound, info_damage, info_deathsound, info_deathstate, info_flags, info_height, info_mass, info_meleestate, info_missilestate, info_painchance, info_painstate, info_radius, info_reactiontime, info_seesound, info_seestate, info_spawnhealth, info_spawnstate, info_speed, info_xdeathstate, kn_caps, lf_count, lf_maxlight, lf_maxtime, lf_minlight, lf_mintime, lf_sector, line_backsector, line_bbox_bottom, line_bbox_left, line_bbox_right, line_bbox_top, line_dx, line_dy, line_flags, line_frontsector, line_side0, line_side1, line_slopetype, line_special, line_tagno, line_v1, line_v2, line_validcount, linespecials, mobj_angle, mobj_bnext, mobj_bprev, mobj_ceilingz, mobj_flags, mobj_floorz, mobj_frame, mobj_health, mobj_height, mobj_lastlook, mobj_momx, mobj_momy, mobj_momz, mobj_movecount, mobj_movedir, mobj_player, mobj_radius, mobj_reactiontime, mobj_sector, mobj_sp_options, mobj_sp_type, mobj_sprite, mobj_state, mobj_subsector, mobj_target, mobj_th, mobj_threshold, mobj_tics, mobj_tracer, mobj_type, mobj_x, mobj_y, mobj_z, node_child0, node_child1, node_dx, node_dy, node_x, node_y, num_anims, num_nodes, num_sectors, numlinespecials, pl_ammo, pl_cards, pl_count, pl_crush, pl_high, pl_low, pl_maxammo, pl_powers, pl_sector, pl_speed, pl_status, pl_tag, pl_th, pl_type, pl_wait, pl_weaponowned, player_mo, psp_state, psp_sx, psp_sy, psp_tics, reject, sector_blockbox, sector_ceilingheight, sector_ceilingpic, sector_floorheight, sector_floorpic, sector_head, sector_lightlevel, sector_linecount, sector_lineofs, sector_lines, sector_soundtarget, sector_soundtraversed, sector_special, sector_specialdata, sector_tagno, sector_validcount, seg_backsector, seg_frontsector, seg_linedef, side_bottomtexture, side_midtexture, side_sector, side_textureoffset, side_toptexture, sight_stack, skill, skyflatnum, sound_stack, spechit, ss_firstline, ss_numlines, ss_sector, st_brighttime, st_count, st_darktime, st_maxlight, st_minlight, st_sector, state, state_action, state_frame, state_misc1, state_misc2, state_nextstate, state_sprite, state_tics, switchlist, tantoangle, texturetranslation, th_data, th_func, th_next, th_prev, thing_next, thing_prev, vertex_x, vertex_y, weapon_ammo, weapon_atkstate, weapon_downstate, weapon_flashstate, weapon_readystate, weapon_upstate, ks, args[1], args[2], args[3], args[4], args[5])
  acc += dc_st_take_message(state, gx)
  acc += dc_st_sb_ticker(state, gx, keyboxes, cards, oldweaponsowned, weaponowned, args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14])
  acc
end
# STEPALL END

# RENDERALL BEGIN -- generated by tests/doom-core/renderall.rb, do not edit
def dc_sp_renderall(state, n_state, rx, n_rx, args, n_args, width, n_width, height, n_height, exec_atlas_size, n_exec_atlas_size, exec_flat_size, n_exec_flat_size, wall, n_wall, span, n_span, masked, n_masked, xcount, n_xcount, xyl, n_xyl, xyh, n_xyh, ycount, n_ycount, yx1, n_yx1, yx2, n_yx2, mcount, n_mcount, mlo, n_mlo, mhi, n_mhi, mseq, n_mseq, mfz, n_mfz, scr, n_scr, cmap, n_cmap, atlas, n_atlas, flat, n_flat, wad, n_wad, zonebuf, n_zonebuf, fuzzoffset, n_fuzzoffset, sc_kind, n_sc_kind, sc_idx, n_sc_idx, exec_width, n_exec_width, exec_centery, n_exec_centery, exec_vwx, n_exec_vwx, exec_vwy, n_exec_vwy, sw, n_sw, sh, n_sh, dst, n_dst, src, n_src, finesine, n_finesine, jobmode, n_jobmode, zero_slots, n_zero_slots, rv_caps, n_rv_caps, ss_first, n_ss_first, ss_last, n_ss_last, viewwidth, n_viewwidth, floorclip, n_floorclip, ceilingclip, n_ceilingclip, cachedheight, n_cachedheight, centerxfrac, n_centerxfrac, viewheight, n_viewheight, bsp_stack, n_bsp_stack, ss_sector, n_ss_sector, ss_numlines, n_ss_numlines, ss_firstline, n_ss_firstline, sector_floorheight, n_sector_floorheight, pl_height, n_pl_height, pl_picnum, n_pl_picnum, pl_lightlevel, n_pl_lightlevel, pl_minx, n_pl_minx, pl_maxx, n_pl_maxx, pl_top, n_pl_top, skyflatnum, n_skyflatnum, plw, n_plw, plempty, n_plempty, sector_floorpic, n_sector_floorpic, sector_lightlevel, n_sector_lightlevel, sector_ceilingheight, n_sector_ceilingheight, sector_ceilingpic, n_sector_ceilingpic, sector_validcount, n_sector_validcount, sector_head, n_sector_head, thing_next, n_thing_next, mobj_x, n_mobj_x, mobj_y, n_mobj_y, mobj_z, n_mobj_z, mobj_angle, n_mobj_angle, mobj_frame, n_mobj_frame, mobj_sprite, n_mobj_sprite, mobj_flags, n_mobj_flags, numframes, n_numframes, rotate, n_rotate, framebase, n_framebase, sprlump, n_sprlump, sprflip, n_sprflip, spriteoffset, n_spriteoffset, spritewidth, n_spritewidth, spritetopoffset, n_spritetopoffset, tantoangle, n_tantoangle, projection, n_projection, scalelight, n_scalelight, resscale, n_resscale, vs_mobjflags, n_vs_mobjflags, vs_scale, n_vs_scale, vs_gx, n_vs_gx, vs_gy, n_vs_gy, vs_gz, n_vs_gz, vs_gzt, n_vs_gzt, vs_texturemid, n_vs_texturemid, vs_x1, n_vs_x1, vs_x2, n_vs_x2, vs_startfrac, n_vs_startfrac, vs_xiscale, n_vs_xiscale, vs_patch, n_vs_patch, vs_cmap, n_vs_cmap, seg_v1, n_seg_v1, seg_v2, n_seg_v2, vertex_x, n_vertex_x, vertex_y, n_vertex_y, clipangle, n_clipangle, two_clipangle, n_two_clipangle, viewangletox, n_viewangletox, seg_backsector, n_seg_backsector, side_midtexture, n_side_midtexture, seg_sidedef, n_seg_sidedef, seg_linedef, n_seg_linedef, line_flags, n_line_flags, seg_angle, n_seg_angle, ds_curline, n_ds_curline, ds_x1, n_ds_x1, ds_x2, n_ds_x2, xtoviewangle, n_xtoviewangle, ds_scale1, n_ds_scale1, ds_scale2, n_ds_scale2, ds_scalestep, n_ds_scalestep, ds_maskedbase, n_ds_maskedbase, ds_masked, n_ds_masked, texturetranslation, n_texturetranslation, tex_theight, n_tex_theight, side_rowoffset, n_side_rowoffset, ds_silhouette, n_ds_silhouette, ds_topkind, n_ds_topkind, ds_botkind, n_ds_botkind, ds_bsilheight, n_ds_bsilheight, ds_tsilheight, n_ds_tsilheight, side_toptexture, n_side_toptexture, side_bottomtexture, n_side_bottomtexture, maxopenings, n_maxopenings, side_textureoffset, n_side_textureoffset, seg_offset, n_seg_offset, centeryfrac, n_centeryfrac, pl_bottom, n_pl_bottom, openings, n_openings, finetangent, n_finetangent, tex_widthmask, n_tex_widthmask, tex_atlas_base, n_tex_atlas_base, zonewin, n_zonewin, centery, n_centery, viewwindowx, n_viewwindowx, viewwindowy, n_viewwindowy, cap_wall, n_cap_wall, cap_sched, n_cap_sched, ds_topbase, n_ds_topbase, ds_botbase, n_ds_botbase, node_x, n_node_x, node_y, n_node_y, node_dx, n_node_dx, node_dy, n_node_dy, node_child0, n_node_child0, node_child1, n_node_child1, node_bbox, n_node_bbox, num_nodes, n_num_nodes, spanstart, n_spanstart, cacheddistance, n_cacheddistance, cachedxstep, n_cachedxstep, cachedystep, n_cachedystep, yslope, n_yslope, distscale, n_distscale, zlight, n_zlight, flattranslation, n_flattranslation, cap_span, n_cap_span, skytexture, n_skytexture, pspriteiscale, n_pspriteiscale, skytexturemid, n_skytexturemid, vs_taken, n_vs_taken, vs_sorted, n_vs_sorted, clipbot, n_clipbot, cliptop, n_cliptop, seg_frontsector, n_seg_frontsector, collump, n_collump, col_base, n_col_base, lump_pos, n_lump_pos, zone_slots, n_zone_slots, lump_size, n_lump_size, next_lump, n_next_lump, cap_masked, n_cap_masked, colofs, n_colofs, spr_lumppos, n_spr_lumppos, spr_lumpnum, n_spr_lumpnum, spr_lumpend, n_spr_lumpend, state_sprite, n_state_sprite, state_frame, n_state_frame, pspritescale, n_pspritescale)
  acc = 0
  acc += dc_rv_draw_jobs_cpu(width, height, exec_atlas_size, exec_flat_size, state, rx, wall, span, masked, xcount, xyl, xyh, ycount, yx1, yx2, mcount, mlo, mhi, mseq, mfz, scr, cmap, atlas, flat, wad, zonebuf, fuzzoffset, sc_kind, sc_idx, exec_width, exec_centery, exec_vwx, exec_vwy)
  acc += dc_rv_clear_screen(sw, sh, scr)
  acc += dc_rv_blit_scale(dst, src, args[0], args[1], args[2], args[3], args[4], args[5], args[6])
  acc += dc_rv_render_player_view(state, rx, finesine, jobmode, zero_slots, rv_caps, ss_first, ss_last, viewwidth, floorclip, ceilingclip, cachedheight, centerxfrac, viewheight, sh, bsp_stack, ss_sector, ss_numlines, ss_firstline, sector_floorheight, pl_height, pl_picnum, pl_lightlevel, pl_minx, pl_maxx, pl_top, skyflatnum, sw, plw, plempty, sector_floorpic, sector_lightlevel, sector_ceilingheight, sector_ceilingpic, sector_validcount, sector_head, thing_next, mobj_x, mobj_y, mobj_z, mobj_angle, mobj_frame, mobj_sprite, mobj_flags, numframes, rotate, framebase, sprlump, sprflip, spriteoffset, spritewidth, spritetopoffset, tantoangle, projection, scalelight, resscale, vs_mobjflags, vs_scale, vs_gx, vs_gy, vs_gz, vs_gzt, vs_texturemid, vs_x1, vs_x2, vs_startfrac, vs_xiscale, vs_patch, vs_cmap, seg_v1, seg_v2, vertex_x, vertex_y, clipangle, two_clipangle, viewangletox, seg_backsector, side_midtexture, seg_sidedef, seg_linedef, line_flags, seg_angle, ds_curline, ds_x1, ds_x2, xtoviewangle, ds_scale1, ds_scale2, ds_scalestep, ds_maskedbase, ds_masked, texturetranslation, tex_theight, side_rowoffset, ds_silhouette, ds_topkind, ds_botkind, ds_bsilheight, ds_tsilheight, side_toptexture, side_bottomtexture, maxopenings, side_textureoffset, seg_offset, centeryfrac, pl_bottom, openings, finetangent, tex_widthmask, tex_atlas_base, scr, cmap, atlas, wad, zonewin, centery, viewwindowx, viewwindowy, wall, sc_kind, sc_idx, cap_wall, cap_sched, ds_topbase, ds_botbase, node_x, node_y, node_dx, node_dy, node_child0, node_child1, node_bbox, num_nodes, spanstart, cacheddistance, cachedxstep, cachedystep, yslope, distscale, zlight, flattranslation, span, cap_span, skytexture, pspriteiscale, skytexturemid, vs_taken, vs_sorted, clipbot, cliptop, seg_frontsector, collump, col_base, lump_pos, zone_slots, lump_size, next_lump, zonebuf, masked, cap_masked, fuzzoffset, colofs, spr_lumppos, spr_lumpnum, spr_lumpend, state_sprite, state_frame, pspritescale, width, height, exec_atlas_size, exec_flat_size, xcount, xyl, xyh, ycount, yx1, yx2, mcount, mlo, mhi, mseq, mfz, flat, exec_width, exec_centery, exec_vwx, exec_vwy, args[7], args[8], args[9], args[10])
  acc
end
# RENDERALL END

# INPUTALL -- the input entry's build-only wrapper (port-first): each root of
# examples/doom/core/src/inputport.rb once, scalars from `args`.
def dc_sp_inputall(state, n_state, xi, n_xi, args, n_args, down, n_down, script_code, n_script_code,
                   script_from, n_script_from, script_to, n_script_to, demo_buf, n_demo_buf,
                   demo_max, n_demo_max)
  acc = 0
  acc += dc_in_apply(down, script_code, script_from, script_to, args[0], args[1])
  acc += dc_in_build(state, xi, down)
  acc += dc_in_quantize_angle(state, xi)
  acc += dc_in_write_tic(state, xi, demo_buf, demo_max, args[2], args[3], args[4], args[5])
  acc
end
