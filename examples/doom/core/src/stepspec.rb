# examples/doom/core/src/stepspec.rb — the step entry's sight, spawning and sector specials.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `mapmove.rb`, `sight.rb`,
# `specials.rb`, `inter.rb` and `enemy.rb` (`Doom::Game`), which reproduce
# doomgeneric's `p_sight.c`, `p_mobj.c`, `p_maputl.c`, `p_map.c`, `p_doors.c`,
# `p_floor.c`, `p_plats.c`, `p_inter.c` and `p_enemy.c`. See ../NOTICE.md and
# ../sources.tsv.
#
# stepcore.rb's convention. Written in the port-first pass: nothing here is
# compared with the original yet.
#
# `cross_bsp_node` is recursive in the original and a preallocated work stack
# here, as 0008 requires. A frame is a node, a phase and the side the walk took:
# phase 0 has not looked at the node, phase 1 waits for the near child's answer,
# phase 2 waits for the far child's, which is the answer. The tree is finite and
# acyclic, so a path holds at most num_nodes frames (sight_stack, three cells a
# frame); a full stack is CAPACITY.

G_TMTHING = 70
G_TMCEILINGZ = 71
G_CEILINGLINE = 72
G_TMFLOORZ = 73
G_TMDROPOFFZ = 74
G_NUMSPECHIT = 75
G_FL_N = 76
G_PL_N = 77
G_PL_ITEMCOUNT = 78

SS_FRACUNIT = 65536
SS_VDOORWAIT = 150
SS_VDOORSPEED = 131072
SS_VLD_NORMAL = 0
SS_VLD_CLOSE30 = 1
SS_VLD_CLOSE = 2
SS_VLD_OPEN = 3
SS_TH_MOBJ = 1
SS_TH_DOOR = 6
SS_TH_PLAT = 7
SS_TH_FLOOR = 8
SS_FT_LOWERFLOOR = 0
SS_FT_LOWERFLOORTOLOWEST = 1
SS_FT_TURBOLOWER = 2
SS_FT_RAISEFLOOR = 3
SS_FT_RAISEFLOORTONEAREST = 4
SS_FLOORSPEED = 65536
SS_PT_DOWNWAITUPSTAY = 1
SS_PT_RAISEANDCHANGE = 2
SS_PT_RAISETONEARESTANDCHANGE = 3
SS_PLATSPEED = 65536
SS_PLATWAIT = 3
SS_TICRATE = 35
SS_PLAT_UP = 0
SS_PLAT_DOWN = 1
SS_ML_BLOCKING = 1
SS_ML_BLOCKMONSTERS = 2
SS_MF_MISSILE = 65536
SS_MF_COUNTITEM = 8388608
SS_ONFLOORZ = -2147483648
SS_ONCEILINGZ = 2147483647
SS_BONUSADD = 6
SS_MAXSPECIALCROSS = 8
SS_MAXTABLE = 64 # state.tsv: fl_sector, pl_sector fixed:64

# ------------------------------------------------------------------- sight

# `P_CrossBSPNode`, over the preallocated stack (see the header)
def dc_st_cross_bsp_node(state, gx, node_x, node_y, node_dx, node_dy, node_child0, node_child1,
                         ss_numlines, ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                         line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x, vertex_y,
                         sector_floorheight, sector_ceilingheight, sight_stack, sight_stack_n, bspnum)
  sight_stack[0] = bspnum
  sight_stack[1] = 0
  sight_stack[2] = 0
  sp = 1
  res = 0
  while sp > 0
    fb = (sp - 1) * 3
    n = sight_stack[fb]
    phase = sight_stack[fb + 1]
    if phase == 0
      if (n & 0x8000) != 0
        leaf = n == -1 ? 0 : n & 0x7fff
        res = dc_st_cross_subsector(state, gx, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                                    seg_backsector, line_validcount, line_v1, line_v2, line_backsector, line_flags,
                                    vertex_x, vertex_y, sector_floorheight, sector_ceilingheight, leaf)
        sp -= 1
        next
      end
      side = dc_st_sight_divline_side(state[gx[G_STRACE_X]], state[gx[G_STRACE_Y]], node_x[n], node_y[n],
                                      node_dx[n], node_dy[n])
      side = 0 if side == 2
      sight_stack[fb + 1] = 1
      sight_stack[fb + 2] = side
      if (sp + 1) * 3 > sight_stack_n
        core_fail(:capacity)
      end
      nb = sp * 3
      sight_stack[nb] = side == 0 ? node_child0[n] : node_child1[n]
      sight_stack[nb + 1] = 0
      sight_stack[nb + 2] = 0
      sp += 1
    elsif phase == 1
      if res == 0
        sp -= 1
        next
      end
      side = sight_stack[fb + 2]
      other = dc_st_sight_divline_side(state[gx[G_T2X]], state[gx[G_T2Y]], node_x[n], node_y[n],
                                       node_dx[n], node_dy[n])
      if side == other
        res = 1
        sp -= 1
        next
      end
      sight_stack[fb + 1] = 2
      nb = sp * 3
      if (sp + 1) * 3 > sight_stack_n
        core_fail(:capacity)
      end
      sight_stack[nb] = side == 0 ? node_child1[n] : node_child0[n]
      sight_stack[nb + 1] = 0
      sight_stack[nb + 2] = 0
      sp += 1
    else
      sp -= 1
    end
  end
  res
end

# `P_CheckSight`
def dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height,
                      node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_numlines, ss_firstline,
                      seg_linedef, seg_frontsector, seg_backsector, line_validcount, line_v1, line_v2,
                      line_backsector, line_flags, vertex_x, vertex_y, sector_floorheight, sector_ceilingheight,
                      sight_stack, sight_stack_n, t1, t2)
  s1 = mobj_sector[t1]
  s2 = mobj_sector[t2]
  pnum = s1 * num_sectors[0] + s2
  return 0 if (reject[pnum >> 3] & (1 << (pnum & 7))) != 0
  state[gx[G_VALIDCOUNT]] = state[gx[G_VALIDCOUNT]] + 1
  zs = core_w32_sub(core_w32_add(mobj_z[t1], mobj_height[t1]), (mobj_height[t1] >> 2))
  state[gx[G_SIGHTZSTART]] = zs
  state[gx[G_TOPSLOPE]] = core_w32_sub(core_w32_add(mobj_z[t2], mobj_height[t2]), zs)
  state[gx[G_BOTTOMSLOPE]] = core_w32_sub(mobj_z[t2], zs)
  state[gx[G_STRACE_X]] = mobj_x[t1]
  state[gx[G_STRACE_Y]] = mobj_y[t1]
  state[gx[G_T2X]] = mobj_x[t2]
  state[gx[G_T2Y]] = mobj_y[t2]
  state[gx[G_STRACE_DX]] = core_w32_sub(mobj_x[t2], mobj_x[t1])
  state[gx[G_STRACE_DY]] = core_w32_sub(mobj_y[t2], mobj_y[t1])
  dc_st_cross_bsp_node(state, gx, node_x, node_y, node_dx, node_dy, node_child0, node_child1,
                       ss_numlines, ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                       line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x, vertex_y,
                       sector_floorheight, sector_ceilingheight, sight_stack, sight_stack_n, num_nodes[0] - 1)
end

# ----------------------------------------------------------------- blockmap

# `P_BlockLinesIterator` with PIT_AddLineIntercepts
def dc_st_block_lines_iterator_addline(state, gx, bmapwidth, bmapheight, blockmap_off, blockmap, line_validcount,
                                       line_v1, line_v2, line_dx, line_dy, line_backsector, vertex_x, vertex_y,
                                       ic_frac, ic_isaline, ic_thing, x, y)
  return 1 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  i = blockmap_off[y * bmapwidth[0] + x]
  vc = state[gx[G_VALIDCOUNT]]
  while blockmap[i] != -1
    v = blockmap[i]
    i += 1
    next if line_validcount[v] == vc
    line_validcount[v] = vc
    if dc_st_pit_add_line_intercepts(state, gx, line_v1, line_v2, line_dx, line_dy, line_backsector, vertex_x,
                                     vertex_y, ic_frac, ic_isaline, ic_thing, v) == 0
      return 0
    end
  end
  1
end

# `PIT_CheckLine`; more than eight special lines is what the original refuses
def dc_st_pit_check_line(state, gx, line_bbox_left, line_bbox_right, line_bbox_top, line_bbox_bottom,
                         line_slopetype, line_v1, line_dx, line_dy, vertex_x, vertex_y, line_backsector,
                         line_frontsector, line_side1, line_flags, line_special, sector_ceilingheight,
                         sector_floorheight, mobj_flags, mobj_player, spechit, ld)
  if state[gx[G_TMBOX_RIGHT]] <= line_bbox_left[ld] || state[gx[G_TMBOX_LEFT]] >= line_bbox_right[ld] ||
     state[gx[G_TMBOX_TOP]] <= line_bbox_bottom[ld] || state[gx[G_TMBOX_BOTTOM]] >= line_bbox_top[ld]
    return 1
  end
  if dc_st_box_on_line_side(state, gx, line_slopetype, line_v1, line_dx, line_dy, vertex_x, vertex_y, ld) != -1
    return 1
  end
  return 0 if line_backsector[ld] < 0
  tm = state[gx[G_TMTHING]]
  if (mobj_flags[tm] & SS_MF_MISSILE) == 0
    return 0 if (line_flags[ld] & SS_ML_BLOCKING) != 0
    if mobj_player[tm] < 0 && (line_flags[ld] & SS_ML_BLOCKMONSTERS) != 0
      return 0
    end
  end
  dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                     sector_floorheight, ld)
  if state[gx[G_OPENTOP]] < state[gx[G_TMCEILINGZ]]
    state[gx[G_TMCEILINGZ]] = state[gx[G_OPENTOP]]
    state[gx[G_CEILINGLINE]] = ld
  end
  state[gx[G_TMFLOORZ]] = state[gx[G_OPENBOTTOM]] if state[gx[G_OPENBOTTOM]] > state[gx[G_TMFLOORZ]]
  state[gx[G_TMDROPOFFZ]] = state[gx[G_LOWFLOOR]] if state[gx[G_LOWFLOOR]] < state[gx[G_TMDROPOFFZ]]
  if line_special[ld] != 0
    n = state[gx[G_NUMSPECHIT]]
    if n >= SS_MAXSPECIALCROSS
      core_fail(:capacity)
    end
    spechit[n] = ld
    state[gx[G_NUMSPECHIT]] = n + 1
  end
  1
end

# ---------------------------------------------------------------- things

# `P_SpawnMobj`
def dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth, info_reactiontime,
                     info_spawnstate, state_tics, state_sprite, state_frame, mobj_x, mobj_y, mobj_z, mobj_momx,
                     mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius, mobj_height, mobj_flags,
                     mobj_health, mobj_movedir, mobj_movecount, mobj_threshold, mobj_target, mobj_tracer,
                     mobj_player, mobj_sp_type, mobj_sp_options, mobj_reactiontime, mobj_lastlook, mobj_state,
                     mobj_tics, mobj_sprite, mobj_frame, mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector,
                     mobj_th, thing_next, thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx,
                     bmaporgy, bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                     node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev, th_func,
                     th_data, x, y, z, type)
  m = dc_st_alloc_mobj(state, gx, thing_next)
  mobj_x[m] = x
  mobj_y[m] = y
  mobj_momx[m] = 0
  mobj_momy[m] = 0
  mobj_momz[m] = 0
  mobj_angle[m] = 0
  mobj_type[m] = type
  mobj_radius[m] = info_radius[type]
  mobj_height[m] = info_height[type]
  mobj_flags[m] = info_flags[type]
  mobj_health[m] = info_spawnhealth[type]
  mobj_movedir[m] = 0
  mobj_movecount[m] = 0
  mobj_threshold[m] = 0
  mobj_target[m] = -1
  mobj_tracer[m] = -1
  mobj_player[m] = -1
  mobj_sp_type[m] = 0
  mobj_sp_options[m] = 0
  mobj_reactiontime[m] = skill[0] == 4 ? 0 : info_reactiontime[type]
  mobj_lastlook[m] = dc_st_p_random(state, gx) % 4
  st = info_spawnstate[type]
  mobj_state[m] = st
  mobj_tics[m] = state_tics[st]
  mobj_sprite[m] = state_sprite[st]
  mobj_frame[m] = state_frame[st]
  dc_st_set_thing_position(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_sector,
                           mobj_x, mobj_y, mobj_flags, mobj_subsector, mobj_sector, thing_next, thing_prev,
                           sector_head, mobj_bnext, mobj_bprev, bmaporgx, bmaporgy, bmapwidth, bmapheight,
                           blocklinks, m)
  sec = mobj_sector[m]
  mobj_floorz[m] = sector_floorheight[sec]
  mobj_ceilingz[m] = sector_ceilingheight[sec]
  if z == SS_ONFLOORZ
    mobj_z[m] = mobj_floorz[m]
  elsif z == SS_ONCEILINGZ
    mobj_z[m] = core_w32_sub(mobj_ceilingz[m], info_height[type])
  else
    mobj_z[m] = z
  end
  mobj_th[m] = dc_st_add_thinker(state, gx, th_next, th_prev, th_func, th_data, SS_TH_MOBJ, m)
  m
end

# `P_TouchSpecialThing`
def dc_st_touch_special_thing(state, gx, player_mo, mobj_health, mobj_flags, pl_cards, pl_powers, skill, pl_ammo,
                              pl_maxammo, pl_weaponowned, weapon_ammo, mobj_z, mobj_height, mobj_sprite,
                              thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext, mobj_bprev, mobj_x,
                              mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, mobj_th, th_func,
                              th_data, special, toucher)
  delta = core_w32_sub(mobj_z[special], mobj_z[toucher])
  return 0 if delta > mobj_height[toucher] || delta < -8 * SS_FRACUNIT
  return 0 if state[gx[G_PL_HEALTH]] <= 0
  spr = mobj_sprite[special]
  if dc_st_give_by_sprite(state, gx, player_mo, mobj_health, mobj_flags, pl_cards, pl_powers, skill, pl_ammo,
                          pl_maxammo, pl_weaponowned, weapon_ammo, spr, special) == 0
    return 0
  end
  if (mobj_flags[special] & SS_MF_COUNTITEM) != 0
    state[gx[G_PL_ITEMCOUNT]] = state[gx[G_PL_ITEMCOUNT]] + 1
  end
  dc_st_remove_mobj(state, gx, mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                    mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks,
                    mobj_th, th_func, th_data, special)
  state[gx[G_PL_BONUSCOUNT]] = state[gx[G_PL_BONUSCOUNT]] + SS_BONUSADD
  0
end

# `P_NoiseAlert`
def dc_st_noise_alert(state, gx, mobj_sector, sector_validcount, sector_soundtraversed, sector_soundtarget,
                      sector_linecount, sector_lineofs, sector_lines, line_flags, line_side0, line_side1,
                      side_sector, line_frontsector, line_backsector, sector_ceilingheight, sector_floorheight,
                      sound_stack, sound_stack_n, target, emmiter)
  state[gx[G_SOUNDTARGET]] = target
  state[gx[G_VALIDCOUNT]] = state[gx[G_VALIDCOUNT]] + 1
  dc_st_recursive_sound(state, gx, sector_validcount, sector_soundtraversed, sector_soundtarget,
                        sector_linecount, sector_lineofs, sector_lines, line_flags, line_side0, line_side1,
                        side_sector, line_frontsector, line_backsector, sector_ceilingheight,
                        sector_floorheight, sound_stack, sound_stack_n, mobj_sector[emmiter], 0)
end

# ---------------------------------------------------------------- doors

# `EV_DoDoor`
def dc_st_ev_do_door(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, dr_th, dr_sector,
                     dr_type, dr_topwait, dr_speed, dr_topheight, dr_direction, th_next, th_prev, th_func, th_data,
                     sector_linecount, sector_lineofs, sector_lines, sector_ceilingheight, line_flags,
                     line_frontsector, line_backsector, line, type)
  secnum = -1
  rtn = 0
  while true
    secnum = dc_st_find_sector_from_line_tag(num_sectors, sector_tagno, line_tagno, line, secnum)
    break if secnum < 0
    next if sector_specialdata[secnum] >= 0
    rtn = 1
    k = dc_st_new_door(state, gx, dr_th, dr_sector, sector_specialdata, th_next, th_prev, th_func, th_data, secnum)
    dr_type[k] = type
    dr_topwait[k] = SS_VDOORWAIT
    dr_speed[k] = SS_VDOORSPEED
    if type == SS_VLD_CLOSE
      dr_topheight[k] = core_w32_sub(dc_st_find_lowest_ceiling_surrounding(sector_linecount, sector_lineofs,
                                                                           sector_lines, sector_ceilingheight,
                                                                           line_flags, line_frontsector,
                                                                           line_backsector, secnum), core_w32_mul(4, SS_FRACUNIT))
      dr_direction[k] = -1
    elsif type == SS_VLD_CLOSE30
      dr_topheight[k] = sector_ceilingheight[secnum]
      dr_direction[k] = -1
    else
      dr_direction[k] = 1
      dr_topheight[k] = core_w32_sub(dc_st_find_lowest_ceiling_surrounding(sector_linecount, sector_lineofs,
                                                                           sector_lines, sector_ceilingheight,
                                                                           line_flags, line_frontsector,
                                                                           line_backsector, secnum), core_w32_mul(4, SS_FRACUNIT))
    end
  end
  rtn
end

# `EV_VerticalDoor`; the plat cross-reference and the unhandled specials are what the original refuses
def dc_st_ev_vertical_door(state, gx, line_special, line_side1, side_sector, mobj_player, pl_cards,
                           sector_specialdata, th_func, th_data, dr_direction, dr_th, dr_sector, dr_type, dr_topwait,
                           dr_speed, dr_topheight, th_next, th_prev, sector_linecount, sector_lineofs, sector_lines,
                           sector_ceilingheight, line_flags, line_frontsector, line_backsector, line, thing)
  sp = line_special[line]
  isplayer = mobj_player[thing] >= 0 ? 1 : 0
  if sp == 26 || sp == 32
    return 0 if isplayer == 0
    if pl_cards[0] == 0 && pl_cards[3] == 0
      state[gx[G_PL_MESSAGE]] = sp == 26 ? 35 : 38
      return 0
    end
  elsif sp == 27 || sp == 34
    return 0 if isplayer == 0
    if pl_cards[1] == 0 && pl_cards[4] == 0
      state[gx[G_PL_MESSAGE]] = sp == 27 ? 36 : 39
      return 0
    end
  elsif sp == 28 || sp == 33
    return 0 if isplayer == 0
    if pl_cards[2] == 0 && pl_cards[5] == 0
      state[gx[G_PL_MESSAGE]] = sp == 28 ? 37 : 40
      return 0
    end
  end
  sec = side_sector[line_side1[line]]
  if sector_specialdata[sec] >= 0
    th = sector_specialdata[sec]
    if sp == 1 || sp == 26 || sp == 27 || sp == 28 || sp == 117
      k = th_data[th]
      if th_func[th] == SS_TH_DOOR
        if dr_direction[k] == -1
          dr_direction[k] = 1
        else
          return 0 if isplayer == 0
          dr_direction[k] = -1
        end
      else
        core_fail(:capacity)
      end
      return 0
    end
  end
  k = dc_st_new_door(state, gx, dr_th, dr_sector, sector_specialdata, th_next, th_prev, th_func, th_data, sec)
  dr_direction[k] = 1
  dr_speed[k] = SS_VDOORSPEED
  dr_topwait[k] = SS_VDOORWAIT
  if sp == 1 || sp == 26 || sp == 27 || sp == 28
    dr_type[k] = SS_VLD_NORMAL
  elsif sp == 31 || sp == 32 || sp == 33 || sp == 34
    dr_type[k] = SS_VLD_OPEN
    line_special[line] = 0
  else
    core_fail(:capacity)
  end
  dr_topheight[k] = core_w32_sub(dc_st_find_lowest_ceiling_surrounding(sector_linecount, sector_lineofs,
                                                                       sector_lines, sector_ceilingheight, line_flags,
                                                                       line_frontsector, line_backsector, sec), core_w32_mul(4, SS_FRACUNIT))
  0
end

# --------------------------------------------------------- floors, plats

# `EV_DoFloor`; the floor types the original does not implement are what it refuses
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "EV_DoFloor: type T not
# implemented" (specials.rb); every caller passes a type it implements: a stated
# limit in tools/doom/core-refusals.tsv.
def dc_st_ev_do_floor(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, fl_th, fl_type,
                      fl_crush, fl_sector, fl_direction, fl_speed, fl_dest, th_next, th_prev, th_func, th_data,
                      sector_linecount, sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight,
                      line_flags, line_frontsector, line_backsector, line, floortype)
  secnum = -1
  rtn = 0
  while true
    secnum = dc_st_find_sector_from_line_tag(num_sectors, sector_tagno, line_tagno, line, secnum)
    break if secnum < 0
    next if sector_specialdata[secnum] >= 0
    rtn = 1
    k = state[gx[G_FL_N]]
    state[gx[G_FL_N]] = k + 1
    if k >= SS_MAXTABLE
      core_fail(:capacity)
    end
    fl_th[k] = dc_st_add_thinker(state, gx, th_next, th_prev, th_func, th_data, SS_TH_FLOOR, k)
    sector_specialdata[secnum] = fl_th[k]
    fl_type[k] = floortype
    fl_crush[k] = 0
    fl_sector[k] = secnum
    if floortype == SS_FT_LOWERFLOOR
      fl_direction[k] = -1
      fl_speed[k] = SS_FLOORSPEED
      fl_dest[k] = dc_st_find_highest_floor_surrounding(sector_linecount, sector_lineofs, sector_lines,
                                                        sector_floorheight, line_flags, line_frontsector,
                                                        line_backsector, secnum)
    elsif floortype == SS_FT_LOWERFLOORTOLOWEST
      fl_direction[k] = -1
      fl_speed[k] = SS_FLOORSPEED
      fl_dest[k] = dc_st_find_lowest_floor_surrounding(sector_linecount, sector_lineofs, sector_lines,
                                                       sector_floorheight, line_flags, line_frontsector,
                                                       line_backsector, secnum)
    elsif floortype == SS_FT_TURBOLOWER
      fl_direction[k] = -1
      fl_speed[k] = SS_FLOORSPEED * 4
      fl_dest[k] = dc_st_find_highest_floor_surrounding(sector_linecount, sector_lineofs, sector_lines,
                                                        sector_floorheight, line_flags, line_frontsector,
                                                        line_backsector, secnum)
      if fl_dest[k] != sector_floorheight[secnum]
        fl_dest[k] = core_w32_add(fl_dest[k], core_w32_mul(8, SS_FRACUNIT))
      end
    elsif floortype == SS_FT_RAISEFLOOR
      fl_direction[k] = 1
      fl_speed[k] = SS_FLOORSPEED
      fl_dest[k] = dc_st_find_lowest_ceiling_surrounding(sector_linecount, sector_lineofs, sector_lines,
                                                         sector_ceilingheight, line_flags, line_frontsector,
                                                         line_backsector, secnum)
      if fl_dest[k] > sector_ceilingheight[secnum]
        fl_dest[k] = sector_ceilingheight[secnum]
      end
    elsif floortype == SS_FT_RAISEFLOORTONEAREST
      fl_direction[k] = 1
      fl_speed[k] = SS_FLOORSPEED
      fl_dest[k] = dc_st_find_next_highest_floor(sector_linecount, sector_lineofs, sector_lines,
                                                 sector_floorheight, line_flags, line_frontsector,
                                                 line_backsector, secnum, sector_floorheight[secnum])
    else
      core_fail(:capacity)
    end
  end
  rtn
end

# `EV_DoPlat`; the plat types the original does not implement are what it refuses
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "EV_DoPlat: type T not
# implemented" (specials.rb); every caller passes a type it implements: a stated
# limit in tools/doom/core-refusals.tsv.
def dc_st_ev_do_plat(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, pl_th, pl_type,
                     pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low, pl_wait, pl_status, activeplats,
                     th_next, th_prev, th_func, th_data, sector_floorpic, sector_special, side_sector, line_side0,
                     sector_linecount, sector_lineofs, sector_lines, sector_floorheight, line_flags,
                     line_frontsector, line_backsector, line, type, amount)
  secnum = -1
  rtn = 0
  while true
    secnum = dc_st_find_sector_from_line_tag(num_sectors, sector_tagno, line_tagno, line, secnum)
    break if secnum < 0
    next if sector_specialdata[secnum] >= 0
    rtn = 1
    k = state[gx[G_PL_N]]
    state[gx[G_PL_N]] = k + 1
    if k >= SS_MAXTABLE
      core_fail(:capacity)
    end
    pl_th[k] = dc_st_add_thinker(state, gx, th_next, th_prev, th_func, th_data, SS_TH_PLAT, k)
    pl_type[k] = type
    pl_sector[k] = secnum
    sector_specialdata[secnum] = pl_th[k]
    pl_crush[k] = 0
    pl_tag[k] = line_tagno[line]
    if type == SS_PT_RAISETONEARESTANDCHANGE
      pl_speed[k] = SS_PLATSPEED / 2
      sector_floorpic[secnum] = sector_floorpic[side_sector[line_side0[line]]]
      pl_high[k] = dc_st_find_next_highest_floor(sector_linecount, sector_lineofs, sector_lines,
                                                 sector_floorheight, line_flags, line_frontsector,
                                                 line_backsector, secnum, sector_floorheight[secnum])
      pl_wait[k] = 0
      pl_status[k] = SS_PLAT_UP
      sector_special[secnum] = 0
    elsif type == SS_PT_RAISEANDCHANGE
      pl_speed[k] = SS_PLATSPEED / 2
      sector_floorpic[secnum] = sector_floorpic[side_sector[line_side0[line]]]
      pl_high[k] = core_w32_add(sector_floorheight[secnum], core_w32_mul(amount, SS_FRACUNIT))
      pl_wait[k] = 0
      pl_status[k] = SS_PLAT_UP
    elsif type == SS_PT_DOWNWAITUPSTAY
      pl_speed[k] = SS_PLATSPEED * 4
      low = dc_st_find_lowest_floor_surrounding(sector_linecount, sector_lineofs, sector_lines,
                                                sector_floorheight, line_flags, line_frontsector,
                                                line_backsector, secnum)
      low = sector_floorheight[secnum] if low > sector_floorheight[secnum]
      pl_low[k] = low
      pl_high[k] = sector_floorheight[secnum]
      pl_wait[k] = SS_TICRATE * SS_PLATWAIT
      pl_status[k] = SS_PLAT_DOWN
    else
      core_fail(:capacity)
    end
    dc_st_add_active_plat(activeplats, k)
  end
  rtn
end

# ---------------------------------------------------------- range and use

G_EXIT_REQUESTED = 79

SS_MELEERANGE = 4194304
SS_MF_JUSTHIT = 64
SS_MT_VILE = 3
SS_MT_UNDEAD = 5
SS_MT_SKULL = 18
SS_MT_SPIDER = 19
SS_MT_CYBORG = 21
SS_ANG90 = 1073741824
SS_ANG270 = -1073741824 # 3221225472, as its signed i32 pattern (decision 0022)
# P_UseSpecialLine's switch, as bit sets over the special number (USE_SPECIALS):
# bit s % 32 of word s / 32, 32-bit words (decision 0022: no constant past i32),
# a word with bit 31 set written as its signed pattern
SS_USE_0 = -1129002366 # 0xbcb4ca82
SS_USE_1 = -259117561 # 0xf08e2e07
SS_USE_2 = 255 # 0x000000ff
SS_USE_3 = -1937800984 # 0x8c7f80e8
SS_USE_4 = 8184 # 0x00001ff8

# `P_BlockLinesIterator` with PIT_CheckLine
def dc_st_block_lines_iterator_checkline(state, gx, bmapwidth, bmapheight, blockmap_off, blockmap, line_validcount,
                                         line_bbox_left, line_bbox_right, line_bbox_top, line_bbox_bottom,
                                         line_slopetype, line_v1, line_dx, line_dy, vertex_x, vertex_y,
                                         line_backsector, line_frontsector, line_side1, line_flags, line_special,
                                         sector_ceilingheight, sector_floorheight, mobj_flags, mobj_player, spechit,
                                         x, y)
  return 1 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  i = blockmap_off[y * bmapwidth[0] + x]
  vc = state[gx[G_VALIDCOUNT]]
  while blockmap[i] != -1
    v = blockmap[i]
    i += 1
    next if line_validcount[v] == vc
    line_validcount[v] = vc
    if dc_st_pit_check_line(state, gx, line_bbox_left, line_bbox_right, line_bbox_top, line_bbox_bottom,
                            line_slopetype, line_v1, line_dx, line_dy, vertex_x, vertex_y, line_backsector,
                            line_frontsector, line_side1, line_flags, line_special, sector_ceilingheight,
                            sector_floorheight, mobj_flags, mobj_player, spechit, v) == 0
      return 0
    end
  end
  1
end

# `P_CheckMeleeRange`
def dc_st_check_melee_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, info_radius,
                            mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y, node_dx, node_dy,
                            node_child0, node_child1, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                            seg_backsector, line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x,
                            vertex_y, sector_floorheight, sector_ceilingheight, sight_stack, sight_stack_n, actor)
  tg = mobj_target[actor]
  return 0 if tg < 0
  dist = dc_st_aprox_distance(core_w32_sub(mobj_x[tg], mobj_x[actor]), core_w32_sub(mobj_y[tg], mobj_y[actor]))
  return 0 if dist >= core_w32_add(core_w32_sub(SS_MELEERANGE, core_w32_mul(20, SS_FRACUNIT)), info_radius[mobj_type[tg]])
  dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height,
                    node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_numlines, ss_firstline,
                    seg_linedef, seg_frontsector, seg_backsector, line_validcount, line_v1, line_v2,
                    line_backsector, line_flags, vertex_x, vertex_y, sector_floorheight, sector_ceilingheight,
                    sight_stack, sight_stack_n, actor, tg)
end

# `P_CheckMissileRange`
def dc_st_check_missile_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, mobj_flags,
                              mobj_reactiontime, info_meleestate, mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height,
                              node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_numlines,
                              ss_firstline, seg_linedef, seg_frontsector, seg_backsector, line_validcount, line_v1,
                              line_v2, line_backsector, line_flags, vertex_x, vertex_y, sector_floorheight,
                              sector_ceilingheight, sight_stack, sight_stack_n, actor)
  tg = mobj_target[actor]
  if dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height,
                       node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_numlines, ss_firstline,
                       seg_linedef, seg_frontsector, seg_backsector, line_validcount, line_v1, line_v2,
                       line_backsector, line_flags, vertex_x, vertex_y, sector_floorheight, sector_ceilingheight,
                       sight_stack, sight_stack_n, actor, tg) == 0
    return 0
  end
  if (mobj_flags[actor] & SS_MF_JUSTHIT) != 0
    mobj_flags[actor] = mobj_flags[actor] & ~SS_MF_JUSTHIT
    return 1
  end
  return 0 if mobj_reactiontime[actor] != 0
  dist = core_w32_sub(dc_st_aprox_distance(core_w32_sub(mobj_x[actor], mobj_x[tg]),
                                           core_w32_sub(mobj_y[actor], mobj_y[tg])), core_w32_mul(64, SS_FRACUNIT))
  dist = core_w32_sub(dist, core_w32_mul(128, SS_FRACUNIT)) if info_meleestate[mobj_type[actor]] == 0
  dist = dist >> 16
  t = mobj_type[actor]
  return 0 if t == SS_MT_VILE && dist > 14 * 64
  if t == SS_MT_UNDEAD
    return 0 if dist < 196
    dist = dist >> 1
  end
  dist = dist >> 1 if t == SS_MT_CYBORG || t == SS_MT_SPIDER || t == SS_MT_SKULL
  dist = 200 if dist > 200
  dist = 160 if t == SS_MT_CYBORG && dist > 160
  return 0 if dc_st_p_random(state, gx) < dist
  1
end

# `P_LookForPlayers` (single player: the other three slots are skipped)
def dc_st_look_for_players(state, gx, player_mo, tantoangle, reject, num_sectors, num_nodes, mobj_lastlook,
                           mobj_target, mobj_angle, mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y,
                           node_dx, node_dy, node_child0, node_child1, ss_numlines, ss_firstline, seg_linedef,
                           seg_frontsector, seg_backsector, line_validcount, line_v1, line_v2, line_backsector,
                           line_flags, vertex_x, vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                           sight_stack_n, actor, allaround)
  c = 0
  stop = (mobj_lastlook[actor] - 1) & 3
  while true
    if mobj_lastlook[actor] != 0
      mobj_lastlook[actor] = (mobj_lastlook[actor] + 1) & 3
      next
    end
    return 0 if c == 2 || mobj_lastlook[actor] == stop
    c += 1
    pm = player_mo[0]
    if state[gx[G_PL_HEALTH]] > 0 &&
       dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector, mobj_x, mobj_y, mobj_z,
                         mobj_height, node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_numlines,
                         ss_firstline, seg_linedef, seg_frontsector, seg_backsector, line_validcount, line_v1,
                         line_v2, line_backsector, line_flags, vertex_x, vertex_y, sector_floorheight,
                         sector_ceilingheight, sight_stack, sight_stack_n, actor, pm) != 0
      ok = 1
      if allaround == 0
        an = core_w32_sub(dc_st_point_to_angle2(tantoangle, mobj_x[actor], mobj_y[actor], mobj_x[pm], mobj_y[pm]), mobj_angle[actor])
        if core_u32_gt(an, SS_ANG90) && core_u32_lt(an, SS_ANG270)
          dist = dc_st_aprox_distance(core_w32_sub(mobj_x[pm], mobj_x[actor]), core_w32_sub(mobj_y[pm], mobj_y[actor]))
          ok = 0 if dist > SS_MELEERANGE
        end
      end
      if ok != 0
        mobj_target[actor] = pm
        return 1
      end
    end
    mobj_lastlook[actor] = (mobj_lastlook[actor] + 1) & 3
  end
  0
end

# whether P_UseSpecialLine's switch names a special
def dc_st_use_special_known(sp)
  return 0 if sp < 0 || sp >= 160
  w = sp / 32
  b = sp % 32
  return (SS_USE_0 >> b) & 1 if w == 0
  return (SS_USE_1 >> b) & 1 if w == 1
  return (SS_USE_2 >> b) & 1 if w == 2
  return (SS_USE_3 >> b) & 1 if w == 3
  (SS_USE_4 >> b) & 1
end

# `P_UseSpecialLine`: the switches the original implements; one it names and
# does not implement is what it refuses; any other special does nothing
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "P_UseSpecialLine: line L
# special S not implemented" for a switch vanilla handles and it does not
# (specials.rb). Reachable: special 9 in E1M2 and others (scenario use-9).
def dc_st_use_special_line(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, line_special,
                           line_side0, line_side1, side_sector, side_toptexture, side_midtexture, side_bottomtexture,
                           switchlist, button_line, button_where, button_texture, button_timer, mobj_player,
                           pl_cards, th_func, th_data, th_next, th_prev, dr_direction, dr_th, dr_sector, dr_type,
                           dr_topwait, dr_speed, dr_topheight, fl_th, fl_type, fl_crush, fl_sector, fl_direction,
                           fl_speed, fl_dest, pl_th, pl_type, pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low,
                           pl_wait, pl_status, activeplats, sector_floorpic, sector_special, sector_linecount,
                           sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight, line_flags,
                           line_frontsector, line_backsector, switchlist_n, thing, line, side)
  return 0 if side != 0
  sp = line_special[line]
  if mobj_player[thing] < 0
    return 0 if (line_flags[line] & 32) != 0
    return 0 unless sp == 1 || sp == 32 || sp == 33 || sp == 34
  end
  if sp == 1 || sp == 26 || sp == 27 || sp == 28 || sp == 31 || sp == 32 || sp == 33 || sp == 34
    dc_st_ev_vertical_door(state, gx, line_special, line_side1, side_sector, mobj_player, pl_cards,
                           sector_specialdata, th_func, th_data, dr_direction, dr_th, dr_sector, dr_type, dr_topwait,
                           dr_speed, dr_topheight, th_next, th_prev, sector_linecount, sector_lineofs, sector_lines,
                           sector_ceilingheight, line_flags, line_frontsector, line_backsector, line, thing)
    return 1
  end
  if sp == 11
    dc_st_change_switch_texture(line_special, line_side0, side_toptexture, side_midtexture, side_bottomtexture,
                                switchlist, button_line, button_where, button_texture, button_timer, switchlist_n,
                                line, 0)
    state[gx[G_EXIT_REQUESTED]] = 1
  elsif sp == 20 || sp == 62
    t = sp == 20 ? SS_PT_RAISETONEARESTANDCHANGE : SS_PT_DOWNWAITUPSTAY
    if dc_st_ev_do_plat(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, pl_th, pl_type,
                        pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low, pl_wait, pl_status, activeplats,
                        th_next, th_prev, th_func, th_data, sector_floorpic, sector_special, side_sector, line_side0,
                        sector_linecount, sector_lineofs, sector_lines, sector_floorheight, line_flags,
                        line_frontsector, line_backsector, line, t, 0) != 0
      dc_st_change_switch_texture(line_special, line_side0, side_toptexture, side_midtexture, side_bottomtexture,
                                  switchlist, button_line, button_where, button_texture, button_timer, switchlist_n,
                                  line, sp == 20 ? 0 : 1)
    end
  elsif sp == 70 || sp == 98
    if dc_st_ev_do_floor(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, fl_th, fl_type,
                         fl_crush, fl_sector, fl_direction, fl_speed, fl_dest, th_next, th_prev, th_func, th_data,
                         sector_linecount, sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight,
                         line_flags, line_frontsector, line_backsector, line, SS_FT_TURBOLOWER) != 0
      dc_st_change_switch_texture(line_special, line_side0, side_toptexture, side_midtexture, side_bottomtexture,
                                  switchlist, button_line, button_where, button_texture, button_timer, switchlist_n,
                                  line, 1)
    end
  elsif sp == 103
    if dc_st_ev_do_door(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, dr_th, dr_sector,
                        dr_type, dr_topwait, dr_speed, dr_topheight, dr_direction, th_next, th_prev, th_func, th_data,
                        sector_linecount, sector_lineofs, sector_lines, sector_ceilingheight, line_flags,
                        line_frontsector, line_backsector, line, SS_VLD_OPEN) != 0
      dc_st_change_switch_texture(line_special, line_side0, side_toptexture, side_midtexture, side_bottomtexture,
                                  switchlist, button_line, button_where, button_texture, button_timer, switchlist_n,
                                  line, 0)
    end
  elsif dc_st_use_special_known(sp) != 0
    core_fail(:capacity)
  end
  1
end
