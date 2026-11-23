# spinel: int64
# examples/doom/core/knot/inter.rb — the knot's damage, state changes and specials, direct style.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `inter.rb` and
# `specials.rb` (`Doom::Game`), which reproduce doomgeneric's `p_mobj.c`,
# `p_inter.c`, `p_map.c`, `p_spec.c` and `p_telept.c`. See ../NOTICE.md and
# ../sources.tsv.
#
# NOT COMPILED. tools/doom/knot-cps.rb reads this and writes
# ../src/stepknot.rb; its header says what this source may contain. Written in
# the port-first pass: nothing here is compared with the original yet.

# `Game#set_mobj_state`: 0 when the mobj was removed
def dc_kn_set_mobj_state(m, st)
  while true
    if st == KN_S_NULL
      mobj_state[m] = KN_S_NULL
      dc_st_remove_mobj(state, gx, mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                        mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, mobj_th,
                        th_func, th_data, m)
      return 0
    end
    mobj_state[m] = st
    mobj_tics[m] = state_tics[st]
    mobj_sprite[m] = state_sprite[st]
    mobj_frame[m] = state_frame[st]
    a = state_action[st]
    if a >= 0
      dc_kn_dispatch_action(a, m)
    end
    st = state_nextstate[st]
    break if mobj_tics[m] != 0
  end
  return 1
end

# `Game#explode_missile`
def dc_kn_explode_missile(m)
  mobj_momx[m] = 0
  mobj_momy[m] = 0
  mobj_momz[m] = 0
  dc_kn_set_mobj_state(m, info_deathstate[mobj_type[m]])
  mobj_tics[m] -= dc_st_p_random(state, gx) & 3
  mobj_tics[m] = 1 if mobj_tics[m] < 1
  mobj_flags[m] &= ~KN_MF_MISSILE
  return 0
end

# `Game#spawn_puff`
def dc_kn_spawn_puff(x, y, z, attackrange)
  r1 = dc_st_p_random(state, gx)
  r2 = dc_st_p_random(state, gx)
  z = core_w32_add(z, core_w32_mul(core_w32_sub(r1, r2), 1024))
  th = dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth, info_reactiontime,
                        info_spawnstate, state_tics, state_sprite, state_frame, mobj_x, mobj_y, mobj_z, mobj_momx,
                        mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius, mobj_height, mobj_flags,
                        mobj_health, mobj_movedir, mobj_movecount, mobj_threshold, mobj_target, mobj_tracer,
                        mobj_player, mobj_sp_type, mobj_sp_options, mobj_reactiontime, mobj_lastlook, mobj_state,
                        mobj_tics, mobj_sprite, mobj_frame, mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector,
                        mobj_th, thing_next, thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx,
                        bmaporgy, bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                        node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev, th_func,
                        th_data, x, y, z, KN_MT_PUFF)
  mobj_momz[th] = KN_FRACUNIT
  mobj_tics[th] -= dc_st_p_random(state, gx) & 3
  mobj_tics[th] = 1 if mobj_tics[th] < 1
  if attackrange == KN_MELEERANGE
    dc_kn_set_mobj_state(th, info_spawnstate[KN_MT_PUFF] + 2)
  end
  return 0
end

# `Game#spawn_blood`
def dc_kn_spawn_blood(x, y, z, damage)
  r1 = dc_st_p_random(state, gx)
  r2 = dc_st_p_random(state, gx)
  z = core_w32_add(z, core_w32_mul(core_w32_sub(r1, r2), 1024))
  th = dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth, info_reactiontime,
                        info_spawnstate, state_tics, state_sprite, state_frame, mobj_x, mobj_y, mobj_z, mobj_momx,
                        mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius, mobj_height, mobj_flags,
                        mobj_health, mobj_movedir, mobj_movecount, mobj_threshold, mobj_target, mobj_tracer,
                        mobj_player, mobj_sp_type, mobj_sp_options, mobj_reactiontime, mobj_lastlook, mobj_state,
                        mobj_tics, mobj_sprite, mobj_frame, mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector,
                        mobj_th, thing_next, thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx,
                        bmaporgy, bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                        node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev, th_func,
                        th_data, x, y, z, KN_MT_BLOOD)
  mobj_momz[th] = KN_FRACUNIT * 2
  mobj_tics[th] -= dc_st_p_random(state, gx) & 3
  mobj_tics[th] = 1 if mobj_tics[th] < 1
  if damage <= 12 && damage >= 9
    dc_kn_set_mobj_state(th, info_spawnstate[KN_MT_BLOOD] + 1)
  elsif damage < 9
    dc_kn_set_mobj_state(th, info_spawnstate[KN_MT_BLOOD] + 2)
  end
  return 0
end

# `Game#damage_mobj`
def dc_kn_damage_mobj(target, inflictor, source, damage)
  return 0 if (mobj_flags[target] & KN_MF_SHOOTABLE) == 0
  return 0 if mobj_health[target] <= 0
  if (mobj_flags[target] & KN_MF_SKULLFLY) != 0
    mobj_momx[target] = 0
    mobj_momy[target] = 0
    mobj_momz[target] = 0
  end
  isplayer = mobj_player[target] >= 0 ? 1 : 0
  damage >>= 1 if isplayer != 0 && skill[0] == 0

  if inflictor >= 0 && (mobj_flags[target] & KN_MF_NOCLIP) == 0 &&
     (source < 0 || mobj_player[source] < 0 || state[gx[G_PL_READYWEAPON]] != KN_WP_CHAINSAW)
    ang = dc_st_point_to_angle2(tantoangle, mobj_x[inflictor], mobj_y[inflictor], mobj_x[target], mobj_y[target])
    thrust = fixed_cdiv(damage * (KN_FRACUNIT >> 3) * 100, info_mass[mobj_type[target]])
    if damage < 40 && damage > mobj_health[target] &&
       core_w32_sub(mobj_z[target], mobj_z[inflictor]) > 64 * KN_FRACUNIT &&
       (dc_st_p_random(state, gx) & 1) != 0
      ang = core_w32_add(ang, KN_ANG180)
      thrust *= 4
    end
    a = core_u32_shr(ang, KN_ANGLETOFINESHIFT)
    mobj_momx[target] = core_w32_add(mobj_momx[target], core_fixed_mul(thrust, finesine[a + 2048]))
    mobj_momy[target] = core_w32_add(mobj_momy[target], core_fixed_mul(thrust, finesine[a]))
  end

  if isplayer != 0
    if sector_special[mobj_sector[target]] == 11 && damage >= mobj_health[target]
      damage = mobj_health[target] - 1
    end
    return 0 if damage < 1000 && pl_powers[KN_PW_INVULNERABILITY] != 0
    if state[gx[G_PL_ARMORTYPE]] != 0
      saved = state[gx[G_PL_ARMORTYPE]] == 1 ? damage / 3 : damage / 2
      if state[gx[G_PL_ARMORPOINTS]] <= saved
        saved = state[gx[G_PL_ARMORPOINTS]]
        state[gx[G_PL_ARMORTYPE]] = 0
      end
      state[gx[G_PL_ARMORPOINTS]] -= saved
      damage -= saved
    end
    state[gx[G_PL_HEALTH]] -= damage
    state[gx[G_PL_HEALTH]] = 0 if state[gx[G_PL_HEALTH]] < 0
    state[gx[G_PL_ATTACKER]] = source
    state[gx[G_PL_DAMAGECOUNT]] += damage
    state[gx[G_PL_DAMAGECOUNT]] = 100 if state[gx[G_PL_DAMAGECOUNT]] > 100
  end

  mobj_health[target] -= damage
  if mobj_health[target] <= 0
    dc_kn_kill_mobj(source, target)
    return 0
  end

  if dc_st_p_random(state, gx) < info_painchance[mobj_type[target]] &&
     (mobj_flags[target] & KN_MF_SKULLFLY) == 0
    mobj_flags[target] |= KN_MF_JUSTHIT
    dc_kn_set_mobj_state(target, info_painstate[mobj_type[target]])
  end
  mobj_reactiontime[target] = 0

  if (mobj_threshold[target] == 0 || mobj_type[target] == KN_MT_VILE) &&
     source >= 0 && source != target && mobj_type[source] != KN_MT_VILE
    mobj_target[target] = source
    mobj_threshold[target] = KN_BASETHRESHOLD
    if mobj_state[target] == info_spawnstate[mobj_type[target]] &&
       info_seestate[mobj_type[target]] != KN_S_NULL
      dc_kn_set_mobj_state(target, info_seestate[mobj_type[target]])
    end
  end
  return 0
end

# `Game#kill_mobj`
def dc_kn_kill_mobj(source, target)
  mobj_flags[target] &= ~(KN_MF_SHOOTABLE | KN_MF_FLOAT | KN_MF_SKULLFLY)
  mobj_flags[target] &= ~KN_MF_NOGRAVITY if mobj_type[target] != KN_MT_SKULL
  mobj_flags[target] |= KN_MF_CORPSE | KN_MF_DROPOFF
  mobj_height[target] >>= 2

  if source >= 0 && mobj_player[source] >= 0
    state[gx[G_PL_KILLCOUNT]] += 1 if (mobj_flags[target] & KN_MF_COUNTKILL) != 0
  elsif (mobj_flags[target] & KN_MF_COUNTKILL) != 0
    state[gx[G_PL_KILLCOUNT]] += 1
  end

  if mobj_player[target] >= 0
    mobj_flags[target] &= ~KN_MF_SOLID
    state[gx[G_PL_PLAYERSTATE]] = KN_PST_DEAD
    dc_kn_drop_weapon()
  end

  if mobj_health[target] < -info_spawnhealth[mobj_type[target]] &&
     info_xdeathstate[mobj_type[target]] != 0
    dc_kn_set_mobj_state(target, info_xdeathstate[mobj_type[target]])
  else
    dc_kn_set_mobj_state(target, info_deathstate[mobj_type[target]])
  end
  mobj_tics[target] -= dc_st_p_random(state, gx) & 3
  mobj_tics[target] = 1 if mobj_tics[target] < 1

  # the drop is a mobjtype number, not a doomednum
  t = mobj_type[target]
  item = -1
  item = 63 if t == 1   # MT_POSSESSED -> MT_CLIP
  item = 77 if t == 2   # MT_SHOTGUY   -> MT_SHOTGUN
  item = 73 if t == 10  # MT_CHAINGUY  -> MT_CHAINGUN
  return 0 if item < 0
  mo = dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth, info_reactiontime,
                        info_spawnstate, state_tics, state_sprite, state_frame, mobj_x, mobj_y, mobj_z, mobj_momx,
                        mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius, mobj_height, mobj_flags,
                        mobj_health, mobj_movedir, mobj_movecount, mobj_threshold, mobj_target, mobj_tracer,
                        mobj_player, mobj_sp_type, mobj_sp_options, mobj_reactiontime, mobj_lastlook, mobj_state,
                        mobj_tics, mobj_sprite, mobj_frame, mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector,
                        mobj_th, thing_next, thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx,
                        bmaporgy, bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                        node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev, th_func,
                        th_data, mobj_x[target], mobj_y[target], KN_ONFLOORZ, item)
  mobj_flags[mo] |= KN_MF_DROPPED
  return 0
end

# `Game#radius_attack`
def dc_kn_radius_attack(spot, source, damage)
  dist = (damage + 32) << 16
  yh = (core_w32_add(mobj_y[spot], dist) - bmaporgy[0]) >> KN_MAPBLOCKSHIFT
  yl = (core_w32_sub(mobj_y[spot], dist) - bmaporgy[0]) >> KN_MAPBLOCKSHIFT
  xh = (core_w32_add(mobj_x[spot], dist) - bmaporgx[0]) >> KN_MAPBLOCKSHIFT
  xl = (core_w32_sub(mobj_x[spot], dist) - bmaporgx[0]) >> KN_MAPBLOCKSHIFT
  state[gx[G_BOMBSPOT]] = spot
  state[gx[G_BOMBSOURCE]] = source
  state[gx[G_BOMBDAMAGE]] = damage
  y = yl
  while y <= yh
    x = xl
    while x <= xh
      dc_kn_block_things_iterator_radius(x, y)
      x += 1
    end
    y += 1
  end
  return 0
end

# `Game#block_things_iterator_radius`
def dc_kn_block_things_iterator_radius(x, y)
  return 0 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  m = blocklinks[y * bmapwidth[0] + x]
  while m >= 0
    nxt = mobj_bnext[m]
    dc_kn_pit_radius_attack(m)
    m = nxt
  end
  return 0
end

# `Game#pit_radius_attack`
def dc_kn_pit_radius_attack(thing)
  return 0 if (mobj_flags[thing] & KN_MF_SHOOTABLE) == 0
  return 0 if mobj_type[thing] == KN_MT_CYBORG || mobj_type[thing] == KN_MT_SPIDER
  dx = dc_st_abs_i(core_w32_sub(mobj_x[thing], mobj_x[state[gx[G_BOMBSPOT]]]))
  dy = dc_st_abs_i(core_w32_sub(mobj_y[thing], mobj_y[state[gx[G_BOMBSPOT]]]))
  dist = dx > dy ? dx : dy
  dist = core_w32_sub(dist, mobj_radius[thing]) >> 16
  dist = 0 if dist < 0
  return 0 if dist >= state[gx[G_BOMBDAMAGE]]
  if dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height,
                       node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_numlines, ss_firstline,
                       seg_linedef, seg_frontsector, seg_backsector, line_validcount, line_v1, line_v2,
                       line_backsector, line_flags, vertex_x, vertex_y, sector_floorheight, sector_ceilingheight,
                       sight_stack, kn_caps[KN_CAP_SIGHT], thing, state[gx[G_BOMBSPOT]]) != 0
    dc_kn_damage_mobj(thing, state[gx[G_BOMBSPOT]], state[gx[G_BOMBSOURCE]], state[gx[G_BOMBDAMAGE]] - dist)
  end
  return 0
end

# `Game#cross_special_line`: the walk-over specials the original implements;
# one P_CrossSpecialLine names and this does not is what it refuses
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "P_CrossSpecialLine: line L
# special S not implemented" for a walk-over special vanilla handles and it does
# not (specials.rb). Reachable: special 36 in E1M1 and others (scenario
# walk-36).
def dc_kn_cross_special_line(line, side, thing)
  sp = line_special[line]
  if mobj_player[thing] < 0
    t = mobj_type[thing]
    return 0 if t == KN_MT_ROCKET || t == KN_MT_PLASMA || t == KN_MT_BFG ||
                t == KN_MT_TROOPSHOT || t == KN_MT_HEADSHOT || t == KN_MT_BRUISERSHOT
    ok = sp == 39 || sp == 97 || sp == 125 || sp == 126 || sp == 4 || sp == 10 || sp == 88 ? 1 : 0
    return 0 if ok == 0
  end
  if sp == 2
    dc_st_ev_do_door(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, dr_th, dr_sector,
                     dr_type, dr_topwait, dr_speed, dr_topheight, dr_direction, th_next, th_prev, th_func, th_data,
                     sector_linecount, sector_lineofs, sector_lines, sector_ceilingheight, line_flags,
                     line_frontsector, line_backsector, line, KN_VLD_OPEN)
    line_special[line] = 0
  elsif sp == 22
    dc_st_ev_do_plat(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, pl_th, pl_type,
                     pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low, pl_wait, pl_status, activeplats,
                     th_next, th_prev, th_func, th_data, sector_floorpic, sector_special, side_sector, line_side0,
                     sector_linecount, sector_lineofs, sector_lines, sector_floorheight, line_flags,
                     line_frontsector, line_backsector, line, KN_PT_RAISETONEARESTANDCHANGE, 0)
    line_special[line] = 0
  elsif sp == 35
    dc_st_ev_light_turn_on(num_sectors, sector_tagno, line_tagno, sector_linecount, sector_lineofs, sector_lines,
                           sector_lightlevel, line_flags, line_frontsector, line_backsector, line, 35)
    line_special[line] = 0
  elsif sp == 88
    dc_st_ev_do_plat(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, pl_th, pl_type,
                     pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low, pl_wait, pl_status, activeplats,
                     th_next, th_prev, th_func, th_data, sector_floorpic, sector_special, side_sector, line_side0,
                     sector_linecount, sector_lineofs, sector_lines, sector_floorheight, line_flags,
                     line_frontsector, line_backsector, line, KN_PT_DOWNWAITUPSTAY, 0)
  elsif sp == 90
    dc_st_ev_do_door(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, dr_th, dr_sector,
                     dr_type, dr_topwait, dr_speed, dr_topheight, dr_direction, th_next, th_prev, th_func, th_data,
                     sector_linecount, sector_lineofs, sector_lines, sector_ceilingheight, line_flags,
                     line_frontsector, line_backsector, line, KN_VLD_NORMAL)
  elsif sp == 91
    dc_st_ev_do_floor(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, fl_th, fl_type,
                      fl_crush, fl_sector, fl_direction, fl_speed, fl_dest, th_next, th_prev, th_func, th_data,
                      sector_linecount, sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight,
                      line_flags, line_frontsector, line_backsector, line, KN_FT_RAISEFLOOR)
  elsif sp == 97
    dc_kn_ev_teleport(line, side, thing)
  elsif sp == 98
    dc_st_ev_do_floor(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, fl_th, fl_type,
                      fl_crush, fl_sector, fl_direction, fl_speed, fl_dest, th_next, th_prev, th_func, th_data,
                      sector_linecount, sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight,
                      line_flags, line_frontsector, line_backsector, line, KN_FT_TURBOLOWER)
  else
    # a special the original's switch does not name does nothing
    if dc_st_walk_special_known(sp) != 0
      core_fail(:capacity)
    end
  end
  return 0
end

# `Game#ev_teleport`: 1 when the thing was teleported
def dc_kn_ev_teleport(line, side, thing)
  return 0 if (mobj_flags[thing] & KN_MF_MISSILE) != 0
  return 0 if side == 1
  tag = line_tagno[line]
  i = 0
  while i < num_sectors[0]
    if sector_tagno[i] == tag
      t = th_next[0]
      while t != 0
        if th_func[t] == KN_TH_MOBJ
          m = th_data[t]
          if mobj_type[m] == KN_MT_TELEPORTMAN && mobj_sector[m] == i
            oldx = mobj_x[thing]
            oldy = mobj_y[thing]
            oldz = mobj_z[thing]
            ok = dc_kn_teleport_move(thing, mobj_x[m], mobj_y[m])
            return 0 if ok == 0
            mobj_z[thing] = mobj_floorz[thing]
            if mobj_player[thing] >= 0
              state[gx[G_PL_VIEWZ]] = core_w32_add(mobj_z[thing], state[gx[G_PL_VIEWHEIGHT]])
            end
            dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth,
                             info_reactiontime, info_spawnstate, state_tics, state_sprite, state_frame, mobj_x,
                             mobj_y, mobj_z, mobj_momx, mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius,
                             mobj_height, mobj_flags, mobj_health, mobj_movedir, mobj_movecount, mobj_threshold,
                             mobj_target, mobj_tracer, mobj_player, mobj_sp_type, mobj_sp_options,
                             mobj_reactiontime, mobj_lastlook, mobj_state, mobj_tics, mobj_sprite, mobj_frame,
                             mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector, mobj_th, thing_next,
                             thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx, bmaporgy,
                             bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                             node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev,
                             th_func, th_data, oldx, oldy, oldz, KN_MT_TFOG)
            an = core_u32_shr(mobj_angle[m], KN_ANGLETOFINESHIFT)
            dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth,
                             info_reactiontime, info_spawnstate, state_tics, state_sprite, state_frame, mobj_x,
                             mobj_y, mobj_z, mobj_momx, mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius,
                             mobj_height, mobj_flags, mobj_health, mobj_movedir, mobj_movecount, mobj_threshold,
                             mobj_target, mobj_tracer, mobj_player, mobj_sp_type, mobj_sp_options,
                             mobj_reactiontime, mobj_lastlook, mobj_state, mobj_tics, mobj_sprite, mobj_frame,
                             mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector, mobj_th, thing_next,
                             thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx, bmaporgy,
                             bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                             node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev,
                             th_func, th_data, core_w32_add(mobj_x[m], core_w32_mul(20, finesine[an + 2048])),
                             core_w32_add(mobj_y[m], core_w32_mul(20, finesine[an])), mobj_z[thing], KN_MT_TFOG)
            mobj_reactiontime[thing] = 18 if mobj_player[thing] >= 0
            mobj_angle[thing] = mobj_angle[m]
            mobj_momx[thing] = 0
            mobj_momy[thing] = 0
            mobj_momz[thing] = 0
            return 1
          end
        end
        t = th_next[t]
      end
    end
    i += 1
  end
  return 0
end
