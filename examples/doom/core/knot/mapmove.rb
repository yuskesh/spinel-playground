# spinel: int64
# examples/doom/core/knot/mapmove.rb — the knot's movement and traversal, direct style.
#
# GPL-derived, from `examples/doom/lib/doom/mapmove.rb` (`Doom::Game`), which
# reproduces doomgeneric's `p_map.c` and `p_maputl.c`. See ../NOTICE.md and
# ../sources.tsv.
#
# NOT COMPILED. tools/doom/knot-cps.rb reads this and writes
# ../src/stepknot.rb; its header says what this source may contain. Written in
# the port-first pass: nothing here is compared with the original yet.

# `Game#try_move`: 1 when the thing moved
def dc_kn_try_move(thing, x, y)
  state[gx[G_FLOATOK]] = 0
  ok = dc_kn_check_position(thing, x, y)
  return 0 if ok == 0
  if (mobj_flags[thing] & KN_MF_NOCLIP) == 0
    return 0 if core_w32_sub(state[gx[G_TMCEILINGZ]], state[gx[G_TMFLOORZ]]) < mobj_height[thing]
    state[gx[G_FLOATOK]] = 1
    if (mobj_flags[thing] & KN_MF_TELEPORT) == 0 &&
       core_w32_sub(state[gx[G_TMCEILINGZ]], mobj_z[thing]) < mobj_height[thing]
      return 0
    end
    if (mobj_flags[thing] & KN_MF_TELEPORT) == 0 &&
       core_w32_sub(state[gx[G_TMFLOORZ]], mobj_z[thing]) > 24 * KN_FRACUNIT
      return 0
    end
    if (mobj_flags[thing] & (KN_MF_DROPOFF | KN_MF_FLOAT)) == 0 &&
       core_w32_sub(state[gx[G_TMFLOORZ]], state[gx[G_TMDROPOFFZ]]) > 24 * KN_FRACUNIT
      return 0
    end
  end
  dc_st_unset_thing_position(mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext, mobj_bprev,
                             mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, thing)
  oldx = mobj_x[thing]
  oldy = mobj_y[thing]
  mobj_floorz[thing] = state[gx[G_TMFLOORZ]]
  mobj_ceilingz[thing] = state[gx[G_TMCEILINGZ]]
  mobj_x[thing] = x
  mobj_y[thing] = y
  dc_st_set_thing_position(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_sector, mobj_x,
                           mobj_y, mobj_flags, mobj_subsector, mobj_sector, thing_next, thing_prev, sector_head,
                           mobj_bnext, mobj_bprev, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, thing)
  if (mobj_flags[thing] & (KN_MF_TELEPORT | KN_MF_NOCLIP)) == 0
    # the original's `while (numspechit--)` walks the hits from the back
    while state[gx[G_NUMSPECHIT]] > 0
      state[gx[G_NUMSPECHIT]] -= 1
      ld = spechit[state[gx[G_NUMSPECHIT]]]
      side = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, mobj_x[thing], mobj_y[thing],
                                      ld)
      oldside = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, oldx, oldy, ld)
      if side != oldside && line_special[ld] != 0
        dc_kn_cross_special_line(ld, oldside, thing)
      end
    end
  end
  return 1
end

# `Game#check_position`: 1 when the thing fits at (x, y)
def dc_kn_check_position(thing, x, y)
  state[gx[G_TMTHING]] = thing
  state[gx[G_TMFLAGS]] = mobj_flags[thing]
  state[gx[G_TMX]] = x
  state[gx[G_TMY]] = y
  r = mobj_radius[thing]
  state[gx[G_TMBOX_TOP]] = core_w32_add(y, r)
  state[gx[G_TMBOX_BOTTOM]] = core_w32_sub(y, r)
  state[gx[G_TMBOX_RIGHT]] = core_w32_add(x, r)
  state[gx[G_TMBOX_LEFT]] = core_w32_sub(x, r)
  newsubsec = dc_st_point_in_subsector(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, x, y)
  state[gx[G_CEILINGLINE]] = -1
  sec = ss_sector[newsubsec]
  state[gx[G_TMFLOORZ]] = sector_floorheight[sec]
  state[gx[G_TMDROPOFFZ]] = state[gx[G_TMFLOORZ]]
  state[gx[G_TMCEILINGZ]] = sector_ceilingheight[sec]
  state[gx[G_VALIDCOUNT]] += 1
  state[gx[G_NUMSPECHIT]] = 0
  return 1 if (state[gx[G_TMFLAGS]] & KN_MF_NOCLIP) != 0

  xl = (state[gx[G_TMBOX_LEFT]] - bmaporgx[0] - KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  xh = (state[gx[G_TMBOX_RIGHT]] - bmaporgx[0] + KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  yl = (state[gx[G_TMBOX_BOTTOM]] - bmaporgy[0] - KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  yh = (state[gx[G_TMBOX_TOP]] - bmaporgy[0] + KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  bx = xl
  while bx <= xh
    by = yl
    while by <= yh
      ok = dc_kn_block_things_iterator_checkthing(bx, by)
      return 0 if ok == 0
      by += 1
    end
    bx += 1
  end

  xl = (state[gx[G_TMBOX_LEFT]] - bmaporgx[0]) >> KN_MAPBLOCKSHIFT
  xh = (state[gx[G_TMBOX_RIGHT]] - bmaporgx[0]) >> KN_MAPBLOCKSHIFT
  yl = (state[gx[G_TMBOX_BOTTOM]] - bmaporgy[0]) >> KN_MAPBLOCKSHIFT
  yh = (state[gx[G_TMBOX_TOP]] - bmaporgy[0]) >> KN_MAPBLOCKSHIFT
  bx = xl
  while bx <= xh
    by = yl
    while by <= yh
      return 0 if dc_st_block_lines_iterator_checkline(state, gx, bmapwidth, bmapheight, blockmap_off, blockmap,
                                                       line_validcount, line_bbox_left, line_bbox_right,
                                                       line_bbox_top, line_bbox_bottom, line_slopetype, line_v1,
                                                       line_dx, line_dy, vertex_x, vertex_y, line_backsector,
                                                       line_frontsector, line_side1, line_flags, line_special,
                                                       sector_ceilingheight, sector_floorheight, mobj_flags,
                                                       mobj_player, spechit, bx, by) == 0
      by += 1
    end
    bx += 1
  end
  return 1
end

# `Game#block_things_iterator_checkthing`: 0 when a thing blocks
def dc_kn_block_things_iterator_checkthing(x, y)
  return 1 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  m = blocklinks[y * bmapwidth[0] + x]
  while m >= 0
    nxt = mobj_bnext[m]
    ok = dc_kn_pit_check_thing(m)
    return 0 if ok == 0
    m = nxt
  end
  return 1
end

# `Game#pit_check_thing`: 1 when th does not block the moving thing
def dc_kn_pit_check_thing(th)
  return 1 if (mobj_flags[th] & (KN_MF_SOLID | KN_MF_SPECIAL | KN_MF_SHOOTABLE)) == 0
  blockdist = core_w32_add(mobj_radius[th], mobj_radius[state[gx[G_TMTHING]]])
  dx = core_w32_sub(mobj_x[th], state[gx[G_TMX]])
  dy = core_w32_sub(mobj_y[th], state[gx[G_TMY]])
  dx = -dx if dx < 0
  dy = -dy if dy < 0
  return 1 if dx >= blockdist || dy >= blockdist
  return 1 if th == state[gx[G_TMTHING]]

  if (mobj_flags[state[gx[G_TMTHING]]] & KN_MF_SKULLFLY) != 0
    damage = ((dc_st_p_random(state, gx) % 8) + 1) * info_damage[mobj_type[state[gx[G_TMTHING]]]]
    dc_kn_damage_mobj(th, state[gx[G_TMTHING]], state[gx[G_TMTHING]], damage)
    mobj_flags[state[gx[G_TMTHING]]] &= ~KN_MF_SKULLFLY
    mobj_momx[state[gx[G_TMTHING]]] = 0
    mobj_momy[state[gx[G_TMTHING]]] = 0
    mobj_momz[state[gx[G_TMTHING]]] = 0
    dc_kn_set_mobj_state(state[gx[G_TMTHING]], info_spawnstate[mobj_type[state[gx[G_TMTHING]]]])
    return 0
  end

  if (mobj_flags[state[gx[G_TMTHING]]] & KN_MF_MISSILE) != 0
    tm = state[gx[G_TMTHING]]
    return 1 if mobj_z[tm] > core_w32_add(mobj_z[th], mobj_height[th])
    return 1 if core_w32_add(mobj_z[tm], mobj_height[tm]) < mobj_z[th]
    tg = mobj_target[tm]
    if tg >= 0 &&
       (mobj_type[tg] == mobj_type[th] ||
        (mobj_type[tg] == KN_MT_KNIGHT && mobj_type[th] == KN_MT_BRUISER) ||
        (mobj_type[tg] == KN_MT_BRUISER && mobj_type[th] == KN_MT_KNIGHT))
      return 1 if th == tg
      return 0 if mobj_type[th] != KN_MT_PLAYER
    end
    if (mobj_flags[th] & KN_MF_SHOOTABLE) == 0
      return (mobj_flags[th] & KN_MF_SOLID) == 0 ? 1 : 0
    end
    damage = ((dc_st_p_random(state, gx) % 8) + 1) * info_damage[mobj_type[tm]]
    dc_kn_damage_mobj(th, tm, mobj_target[tm], damage)
    return 0
  end

  if (mobj_flags[th] & KN_MF_SPECIAL) != 0
    solid = (mobj_flags[th] & KN_MF_SOLID) != 0 ? 1 : 0
    if (state[gx[G_TMFLAGS]] & KN_MF_PICKUP) != 0
      dc_st_touch_special_thing(state, gx, player_mo, mobj_health, mobj_flags, pl_cards, pl_powers, skill, pl_ammo,
                                pl_maxammo, pl_weaponowned, weapon_ammo, mobj_z, mobj_height, mobj_sprite,
                                thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext, mobj_bprev, mobj_x,
                                mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, mobj_th, th_func,
                                th_data, th, state[gx[G_TMTHING]])
    end
    return solid == 0 ? 1 : 0
  end
  return (mobj_flags[th] & KN_MF_SOLID) == 0 ? 1 : 0
end

# `Game#teleport_move`: 1 when the thing was placed at (x, y)
def dc_kn_teleport_move(thing, x, y)
  state[gx[G_TMTHING]] = thing
  state[gx[G_TMFLAGS]] = mobj_flags[thing]
  state[gx[G_TMX]] = x
  state[gx[G_TMY]] = y
  r = mobj_radius[thing]
  state[gx[G_TMBOX_TOP]] = core_w32_add(y, r)
  state[gx[G_TMBOX_BOTTOM]] = core_w32_sub(y, r)
  state[gx[G_TMBOX_RIGHT]] = core_w32_add(x, r)
  state[gx[G_TMBOX_LEFT]] = core_w32_sub(x, r)
  newsubsec = dc_st_point_in_subsector(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, x, y)
  state[gx[G_CEILINGLINE]] = -1
  sec = ss_sector[newsubsec]
  state[gx[G_TMFLOORZ]] = sector_floorheight[sec]
  state[gx[G_TMDROPOFFZ]] = state[gx[G_TMFLOORZ]]
  state[gx[G_TMCEILINGZ]] = sector_ceilingheight[sec]
  state[gx[G_VALIDCOUNT]] += 1
  state[gx[G_NUMSPECHIT]] = 0
  xl = (state[gx[G_TMBOX_LEFT]] - bmaporgx[0] - KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  xh = (state[gx[G_TMBOX_RIGHT]] - bmaporgx[0] + KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  yl = (state[gx[G_TMBOX_BOTTOM]] - bmaporgy[0] - KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  yh = (state[gx[G_TMBOX_TOP]] - bmaporgy[0] + KN_MAXRADIUS) >> KN_MAPBLOCKSHIFT
  bx = xl
  while bx <= xh
    by = yl
    while by <= yh
      ok = dc_kn_block_things_iterator_stomp(bx, by)
      return 0 if ok == 0
      by += 1
    end
    bx += 1
  end
  dc_st_unset_thing_position(mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext, mobj_bprev,
                             mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, thing)
  mobj_floorz[thing] = state[gx[G_TMFLOORZ]]
  mobj_ceilingz[thing] = state[gx[G_TMCEILINGZ]]
  mobj_x[thing] = x
  mobj_y[thing] = y
  dc_st_set_thing_position(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_sector, mobj_x,
                           mobj_y, mobj_flags, mobj_subsector, mobj_sector, thing_next, thing_prev, sector_head,
                           mobj_bnext, mobj_bprev, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, thing)
  return 1
end

# `Game#block_things_iterator_stomp`: 0 when a thing cannot be stomped
def dc_kn_block_things_iterator_stomp(x, y)
  return 1 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  m = blocklinks[y * bmapwidth[0] + x]
  while m >= 0
    nxt = mobj_bnext[m]
    ok = dc_kn_pit_stomp_thing(m)
    return 0 if ok == 0
    m = nxt
  end
  return 1
end

# `Game#pit_stomp_thing`: 0 when the teleporting thing is blocked
def dc_kn_pit_stomp_thing(thing)
  return 1 if (mobj_flags[thing] & KN_MF_SHOOTABLE) == 0
  blockdist = core_w32_add(mobj_radius[thing], mobj_radius[state[gx[G_TMTHING]]])
  dx = core_w32_sub(mobj_x[thing], state[gx[G_TMX]])
  dy = core_w32_sub(mobj_y[thing], state[gx[G_TMY]])
  dx = -dx if dx < 0
  dy = -dy if dy < 0
  return 1 if dx >= blockdist || dy >= blockdist
  return 1 if thing == state[gx[G_TMTHING]]
  # `gamemap != 30` always holds in shareware: monsters do not telefrag
  return 0 if mobj_player[state[gx[G_TMTHING]]] < 0
  dc_kn_damage_mobj(thing, state[gx[G_TMTHING]], state[gx[G_TMTHING]], 10000)
  return 1
end

# `Game#path_traverse`: 0 when a traverser stopped the walk
def dc_kn_path_traverse(x1, y1, x2, y2, flags)
  state[gx[G_EARLYOUT]] = (flags & 4) != 0 ? 1 : 0
  state[gx[G_VALIDCOUNT]] += 1
  state[gx[G_IC_N]] = 0
  x1 = core_w32_add(x1, KN_FRACUNIT) if ((x1 - bmaporgx[0]) & (KN_MAPBLOCKSIZE - 1)) == 0
  y1 = core_w32_add(y1, KN_FRACUNIT) if ((y1 - bmaporgy[0]) & (KN_MAPBLOCKSIZE - 1)) == 0
  state[gx[G_TRACE_X]] = x1
  state[gx[G_TRACE_Y]] = y1
  state[gx[G_TRACE_DX]] = core_w32_sub(x2, x1)
  state[gx[G_TRACE_DY]] = core_w32_sub(y2, y1)
  x1 = core_w32_sub(x1, bmaporgx[0])
  y1 = core_w32_sub(y1, bmaporgy[0])
  xt1 = x1 >> KN_MAPBLOCKSHIFT
  yt1 = y1 >> KN_MAPBLOCKSHIFT
  x2 = core_w32_sub(x2, bmaporgx[0])
  y2 = core_w32_sub(y2, bmaporgy[0])
  xt2 = x2 >> KN_MAPBLOCKSHIFT
  yt2 = y2 >> KN_MAPBLOCKSHIFT

  if xt2 > xt1
    mapxstep = 1
    partial = KN_FRACUNIT - ((x1 >> KN_MAPBTOFRAC) & (KN_FRACUNIT - 1))
    ystep = core_fixed_div(core_w32_sub(y2, y1), dc_st_abs_i(core_w32_sub(x2, x1)))
  elsif xt2 < xt1
    mapxstep = -1
    partial = (x1 >> KN_MAPBTOFRAC) & (KN_FRACUNIT - 1)
    ystep = core_fixed_div(core_w32_sub(y2, y1), dc_st_abs_i(core_w32_sub(x2, x1)))
  else
    mapxstep = 0
    partial = KN_FRACUNIT
    ystep = 256 * KN_FRACUNIT
  end
  yintercept = core_w32_add((y1 >> KN_MAPBTOFRAC), core_fixed_mul(partial, ystep))

  if yt2 > yt1
    mapystep = 1
    partial = KN_FRACUNIT - ((y1 >> KN_MAPBTOFRAC) & (KN_FRACUNIT - 1))
    xstep = core_fixed_div(core_w32_sub(x2, x1), dc_st_abs_i(core_w32_sub(y2, y1)))
  elsif yt2 < yt1
    mapystep = -1
    partial = (y1 >> KN_MAPBTOFRAC) & (KN_FRACUNIT - 1)
    xstep = core_fixed_div(core_w32_sub(x2, x1), dc_st_abs_i(core_w32_sub(y2, y1)))
  else
    mapystep = 0
    partial = KN_FRACUNIT
    xstep = 256 * KN_FRACUNIT
  end
  xintercept = core_w32_add((x1 >> KN_MAPBTOFRAC), core_fixed_mul(partial, xstep))

  mapx = xt1
  mapy = yt1
  count = 0
  while count < 64
    if (flags & 1) != 0
      return 0 if dc_st_block_lines_iterator_addline(state, gx, bmapwidth, bmapheight, blockmap_off, blockmap,
                                                     line_validcount, line_v1, line_v2, line_dx, line_dy,
                                                     line_backsector, vertex_x, vertex_y, ic_frac, ic_isaline,
                                                     ic_thing, mapx, mapy) == 0
    end
    if (flags & 2) != 0
      return 0 if dc_st_block_things_iterator_addthing(state, gx, bmapwidth, bmapheight, blocklinks, mobj_bnext,
                                                       mobj_radius, mobj_x, mobj_y, ic_frac, ic_isaline, ic_thing,
                                                       mapx, mapy) == 0
    end
    break if mapx == xt2 && mapy == yt2
    if (yintercept >> 16) == mapy
      yintercept = core_w32_add(yintercept, ystep)
      mapx += mapxstep
    elsif (xintercept >> 16) == mapx
      xintercept = core_w32_add(xintercept, xstep)
      mapy += mapystep
    end
    count += 1
  end
  return dc_kn_traverse_intercepts(KN_FRACUNIT)
end

# `Game#traverse_intercepts`: 0 when a traverser stopped the walk
def dc_kn_traverse_intercepts(maxfrac)
  count = state[gx[G_IC_N]]
  inn = -1
  while count > 0
    count -= 1
    dist = 0x7fffffff
    scan = 0
    while scan < state[gx[G_IC_N]]
      if ic_frac[scan] < dist
        dist = ic_frac[scan]
        inn = scan
      end
      scan += 1
    end
    return 1 if dist > maxfrac
    ok = dc_kn_dispatch_traverse(inn)
    return 0 if ok == 0
    ic_frac[inn] = 0x7fffffff
  end
  return 1
end

# `Game#dispatch_traverse`: the current traverser's answer for intercept idx
def dc_kn_dispatch_traverse(idx)
  tr = state[gx[G_TRAVERSER]]
  # nested, not a chain: an == chain became a jump table
  if tr <= 2
    if tr == 1
      return dc_st_ptr_slide_traverse(state, gx, line_flags, line_side1, line_frontsector, line_backsector,
                                      sector_ceilingheight, sector_floorheight, line_dx, line_dy, line_v1, vertex_x,
                                      vertex_y, ic_frac, ic_isaline, ic_thing, mobj_x, mobj_y, mobj_z, mobj_height,
                                      idx)
    else
      if tr == 2
        return dc_st_ptr_use_traverse(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata,
                                      line_special, line_side0, line_side1, side_sector, side_toptexture,
                                      side_midtexture, side_bottomtexture, switchlist, button_line, button_where,
                                      button_texture, button_timer, mobj_player, pl_cards, th_func, th_data,
                                      th_next, th_prev, dr_direction, dr_th, dr_sector, dr_type, dr_topwait,
                                      dr_speed, dr_topheight, fl_th, fl_type, fl_crush, fl_sector, fl_direction,
                                      fl_speed, fl_dest, pl_th, pl_type, pl_sector, pl_crush, pl_tag, pl_speed,
                                      pl_high, pl_low, pl_wait, pl_status, activeplats, sector_floorpic,
                                      sector_special, sector_linecount, sector_lineofs, sector_lines,
                                      sector_floorheight, sector_ceilingheight, line_flags, line_frontsector,
                                      line_backsector, line_dx, line_dy, line_v1, vertex_x, vertex_y, mobj_x,
                                      mobj_y, ic_thing, kn_caps[KN_CAP_SWITCH], idx)
      end
    end
  else
    if tr == 3
      return dc_st_ptr_aim_traverse(state, gx, line_flags, line_side1, line_frontsector, line_backsector,
                                    sector_ceilingheight, sector_floorheight, ic_frac, ic_isaline, ic_thing,
                                    mobj_flags, mobj_z, mobj_height, idx)
    else
      if tr == 4
        return dc_kn_ptr_shoot_traverse(idx)
      end
    end
  end
  return 1
end
