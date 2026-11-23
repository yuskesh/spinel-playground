# spinel: int64
# examples/doom/core/knot/enemy.rb — the knot's monster actions, direct style.
#
# GPL-derived, from `examples/doom/lib/doom/enemy.rb` (`Doom::Game`), which
# reproduces doomgeneric's `p_enemy.c`. See ../NOTICE.md and ../sources.tsv.
#
# NOT COMPILED. tools/doom/knot-cps.rb reads this and writes
# ../src/stepknot.rb; its header says what this source may contain. Written in
# the port-first pass: nothing here is compared with the original yet.

# `Game#dispatch_action`
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): every leaf with no action raises in the
# original, "unimplemented mobj action A" (enemy.rb). No type doom1.wad places
# reaches one: a stated limit in tools/doom/core-refusals.tsv.
def dc_kn_dispatch_action(a, m)
  # a range tree over the action ids: an == chain became a jump table.
  # The two A_Chase sites of the original are the chase group and ACT_CHASE.
  chase = a == KN_ACT_HOOF || a == KN_ACT_METAL || a == KN_ACT_BABYMETAL || a == KN_ACT_FIRECRACKLE ? 1 : 0
  sound = a == KN_ACT_XSCREAM || a == KN_ACT_PAIN || a == KN_ACT_PLAYERSCREAM ? 1 : 0
  if chase != 0
    dc_kn_a_chase(m)
  else
    if sound == 0
      if a <= KN_ACT_FALL
        if a <= KN_ACT_CPOSATTACK
          if a <= KN_ACT_BRUISATTACK
            if a <= KN_ACT_BOSSDEATH
              if a == KN_ACT_BOSSDEATH
                dc_st_a_boss_death(m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_BRUISATTACK
                dc_kn_a_bruis_attack(m)
              else
                core_fail(:capacity)
              end
            end
          else
            if a <= KN_ACT_CHASE
              if a == KN_ACT_CHASE
                dc_kn_a_chase(m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_CPOSATTACK
                dc_kn_a_cpos_attack(m)
              else
                core_fail(:capacity)
              end
            end
          end
        else
          if a <= KN_ACT_EXPLODE
            if a <= KN_ACT_CPOSREFIRE
              if a == KN_ACT_CPOSREFIRE
                dc_kn_a_cpos_refire(m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_EXPLODE
                dc_kn_a_explode(m)
              else
                core_fail(:capacity)
              end
            end
          else
            if a <= KN_ACT_FACETARGET
              if a == KN_ACT_FACETARGET
                dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_FALL
                dc_st_a_fall(mobj_flags, m)
              else
                core_fail(:capacity)
              end
            end
          end
        end
      else
        if a <= KN_ACT_SARGATTACK
          if a <= KN_ACT_LOOK
            if a <= KN_ACT_HEADATTACK
              if a == KN_ACT_HEADATTACK
                dc_kn_a_head_attack(m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_LOOK
                dc_kn_a_look(m)
              else
                core_fail(:capacity)
              end
            end
          else
            if a <= KN_ACT_POSATTACK
              if a == KN_ACT_POSATTACK
                dc_kn_a_pos_attack(m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_SARGATTACK
                dc_kn_a_sarg_attack(m)
              else
                core_fail(:capacity)
              end
            end
          end
        else
          if a <= KN_ACT_SKULLATTACK
            if a <= KN_ACT_SCREAM
              if a == KN_ACT_SCREAM
                dc_st_a_scream(state, gx, mobj_type, info_deathsound, m)
              else
                core_fail(:capacity)
              end
            else
              if a == KN_ACT_SKULLATTACK
                dc_st_a_skull_attack(state, gx, tantoangle, finesine, mobj_target, mobj_flags, mobj_angle, mobj_x,
                                     mobj_y, mobj_z, mobj_height, mobj_momx, mobj_momy, mobj_momz, m)
              else
                core_fail(:capacity)
              end
            end
          else
            if a <= KN_ACT_SPIDREFIRE
              if a == KN_ACT_SPIDREFIRE
                dc_kn_a_spid_refire(m)
              else
                core_fail(:capacity)
              end
            else
              if a <= KN_ACT_SPOSATTACK
                if a == KN_ACT_SPOSATTACK
                  dc_kn_a_spos_attack(m)
                else
                  core_fail(:capacity)
                end
              else
                if a == KN_ACT_TROOPATTACK
                  dc_kn_a_troop_attack(m)
                else
                  core_fail(:capacity)
                end
              end
            end
          end
        end
      end
    end
  end
  return 0
end

# `Game#a_look`
def dc_kn_a_look(actor)
  mobj_threshold[actor] = 0
  targ = sector_soundtarget[mobj_sector[actor]]
  seeyou = 0
  if targ >= 0 && (mobj_flags[targ] & KN_MF_SHOOTABLE) != 0
    mobj_target[actor] = targ
    if (mobj_flags[actor] & KN_MF_AMBUSH) != 0
      seeyou = 1 if dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector, mobj_x, mobj_y,
                                      mobj_z, mobj_height, node_x, node_y, node_dx, node_dy, node_child0,
                                      node_child1, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                                      seg_backsector, line_validcount, line_v1, line_v2, line_backsector,
                                      line_flags, vertex_x, vertex_y, sector_floorheight, sector_ceilingheight,
                                      sight_stack, kn_caps[KN_CAP_SIGHT], actor, targ) != 0
    else
      seeyou = 1
    end
  end
  if seeyou == 0
    return 0 if dc_st_look_for_players(state, gx, player_mo, tantoangle, reject, num_sectors, num_nodes,
                                       mobj_lastlook, mobj_target, mobj_angle, mobj_sector, mobj_x, mobj_y, mobj_z,
                                       mobj_height, node_x, node_y, node_dx, node_dy, node_child0, node_child1,
                                       ss_numlines, ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                                       line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x,
                                       vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                                       kn_caps[KN_CAP_SIGHT], actor, 0) == 0
  end
  ss = info_seesound[mobj_type[actor]]
  if ss != 0
    if ss == KN_SFX_POSIT1 || ss == KN_SFX_POSIT1 + 1 || ss == KN_SFX_POSIT1 + 2
      dc_st_p_random(state, gx)
    elsif ss == KN_SFX_BGSIT1 || ss == KN_SFX_BGSIT1 + 1
      dc_st_p_random(state, gx)
    end
  end
  dc_kn_set_mobj_state(actor, info_seestate[mobj_type[actor]])
  return 0
end

# `Game#a_chase`
def dc_kn_a_chase(actor)
  mobj_reactiontime[actor] -= 1 if mobj_reactiontime[actor] != 0
  if mobj_threshold[actor] != 0
    tg = mobj_target[actor]
    if tg < 0 || mobj_health[tg] <= 0
      mobj_threshold[actor] = 0
    else
      mobj_threshold[actor] -= 1
    end
  end
  if mobj_movedir[actor] < 8
    # the top three bits of the angle (C: & (7 << 29)); 7 << 29 is 0xe0000000,
    # here its signed pattern (decision 0022)
    mobj_angle[actor] &= -536870912
    delta = core_w32_sub(mobj_angle[actor], core_w32_mul(mobj_movedir[actor], 536870912))
    if delta > 0
      mobj_angle[actor] = core_w32_sub(mobj_angle[actor], KN_ANG90 / 2)
    elsif delta < 0
      mobj_angle[actor] = core_w32_add(mobj_angle[actor], KN_ANG90 / 2)
    end
  end
  tg = mobj_target[actor]
  if tg < 0 || (mobj_flags[tg] & KN_MF_SHOOTABLE) == 0
    return 0 if dc_st_look_for_players(state, gx, player_mo, tantoangle, reject, num_sectors, num_nodes,
                                       mobj_lastlook, mobj_target, mobj_angle, mobj_sector, mobj_x, mobj_y, mobj_z,
                                       mobj_height, node_x, node_y, node_dx, node_dy, node_child0, node_child1,
                                       ss_numlines, ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                                       line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x,
                                       vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                                       kn_caps[KN_CAP_SIGHT], actor, 1) != 0
    dc_kn_set_mobj_state(actor, info_spawnstate[mobj_type[actor]])
    return 0
  end
  if (mobj_flags[actor] & KN_MF_JUSTATTACKED) != 0
    mobj_flags[actor] &= ~KN_MF_JUSTATTACKED
    if skill[0] != 4
      dc_kn_new_chase_dir(actor)
    end
    return 0
  end
  if info_meleestate[mobj_type[actor]] != 0 && dc_st_check_melee_range(state, gx, reject, num_sectors, num_nodes,
                                                                       mobj_target, mobj_type, info_radius,
                                                                       mobj_sector, mobj_x, mobj_y, mobj_z,
                                                                       mobj_height, node_x, node_y, node_dx,
                                                                       node_dy, node_child0, node_child1,
                                                                       ss_numlines, ss_firstline, seg_linedef,
                                                                       seg_frontsector, seg_backsector,
                                                                       line_validcount, line_v1, line_v2,
                                                                       line_backsector, line_flags, vertex_x,
                                                                       vertex_y, sector_floorheight,
                                                                       sector_ceilingheight, sight_stack,
                                                                       kn_caps[KN_CAP_SIGHT], actor) != 0
    dc_kn_set_mobj_state(actor, info_meleestate[mobj_type[actor]])
    return 0
  end
  nomissile = 0
  if info_missilestate[mobj_type[actor]] != 0
    if skill[0] < 4 && mobj_movecount[actor] != 0
      nomissile = 1
    elsif dc_st_check_missile_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, mobj_flags,
                                    mobj_reactiontime, info_meleestate, mobj_sector, mobj_x, mobj_y, mobj_z,
                                    mobj_height, node_x, node_y, node_dx, node_dy, node_child0, node_child1,
                                    ss_numlines, ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                                    line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x,
                                    vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                                    kn_caps[KN_CAP_SIGHT], actor) == 0
      nomissile = 1
    end
    if nomissile == 0
      dc_kn_set_mobj_state(actor, info_missilestate[mobj_type[actor]])
      mobj_flags[actor] |= KN_MF_JUSTATTACKED
      return 0
    end
  end
  # the netgame branch is not taken in single player
  mobj_movecount[actor] -= 1
  mc = mobj_movecount[actor]
  moved = 0
  if mc >= 0
    moved = dc_kn_p_move(actor)
  end
  if mc < 0 || moved == 0
    dc_kn_new_chase_dir(actor)
  end
  if info_activesound[mobj_type[actor]] != 0
    dc_st_p_random(state, gx)
  end
  return 0
end

# `Game#a_explode`
def dc_kn_a_explode(actor)
  dc_kn_radius_attack(actor, mobj_target[actor], 128)
  return 0
end

# `Game#p_move`
def dc_kn_p_move(actor)
  return 0 if mobj_movedir[actor] == KN_DI_NODIR
  if mobj_movedir[actor] >= 8
    core_fail(:capacity)
  end
  speed = info_speed[mobj_type[actor]]
  tryx = core_w32_add(mobj_x[actor], core_w32_mul(speed, dc_st_xspeed(mobj_movedir[actor])))
  tryy = core_w32_add(mobj_y[actor], core_w32_mul(speed, dc_st_yspeed(mobj_movedir[actor])))
  ok = dc_kn_try_move(actor, tryx, tryy)
  if ok != 0
    mobj_flags[actor] &= ~KN_MF_INFLOAT
    mobj_z[actor] = mobj_floorz[actor] if (mobj_flags[actor] & KN_MF_FLOAT) == 0
    return 1
  end
  if (mobj_flags[actor] & KN_MF_FLOAT) != 0 && state[gx[G_FLOATOK]] != 0
    if mobj_z[actor] < state[gx[G_TMFLOORZ]]
      mobj_z[actor] = core_w32_add(mobj_z[actor], KN_FLOATSPEED)
    else
      mobj_z[actor] = core_w32_sub(mobj_z[actor], KN_FLOATSPEED)
    end
    mobj_flags[actor] |= KN_MF_INFLOAT
    return 1
  end
  return 0 if state[gx[G_NUMSPECHIT]] == 0
  mobj_movedir[actor] = KN_DI_NODIR
  good = 0
  while state[gx[G_NUMSPECHIT]] > 0
    state[gx[G_NUMSPECHIT]] -= 1
    hit = spechit[state[gx[G_NUMSPECHIT]]]
    good = 1 if dc_st_use_special_line(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata,
                                       line_special, line_side0, line_side1, side_sector, side_toptexture,
                                       side_midtexture, side_bottomtexture, switchlist, button_line, button_where,
                                       button_texture, button_timer, mobj_player, pl_cards, th_func, th_data,
                                       th_next, th_prev, dr_direction, dr_th, dr_sector, dr_type, dr_topwait,
                                       dr_speed, dr_topheight, fl_th, fl_type, fl_crush, fl_sector, fl_direction,
                                       fl_speed, fl_dest, pl_th, pl_type, pl_sector, pl_crush, pl_tag, pl_speed,
                                       pl_high, pl_low, pl_wait, pl_status, activeplats, sector_floorpic,
                                       sector_special, sector_linecount, sector_lineofs, sector_lines,
                                       sector_floorheight, sector_ceilingheight, line_flags, line_frontsector,
                                       line_backsector, kn_caps[KN_CAP_SWITCH], actor, hit, 0) != 0
  end
  return good
end

# `Game#try_walk`
def dc_kn_try_walk(actor)
  ok = dc_kn_p_move(actor)
  return 0 if ok == 0
  mobj_movecount[actor] = dc_st_p_random(state, gx) & 15
  return 1
end

# `Game#new_chase_dir`
def dc_kn_new_chase_dir(actor)
  tg = mobj_target[actor]
  if tg < 0
    core_fail(:capacity)
  end
  olddir = mobj_movedir[actor]
  turnaround = dc_st_opposite_dir(olddir)
  deltax = core_w32_sub(mobj_x[tg], mobj_x[actor])
  deltay = core_w32_sub(mobj_y[tg], mobj_y[actor])
  if deltax > 10 * KN_FRACUNIT
    d1 = KN_DI_EAST
  elsif deltax < -10 * KN_FRACUNIT
    d1 = KN_DI_WEST
  else
    d1 = KN_DI_NODIR
  end
  if deltay < -10 * KN_FRACUNIT
    d2 = KN_DI_SOUTH
  elsif deltay > 10 * KN_FRACUNIT
    d2 = KN_DI_NORTH
  else
    d2 = KN_DI_NODIR
  end
  if d1 != KN_DI_NODIR && d2 != KN_DI_NODIR
    mobj_movedir[actor] = dc_st_diag_dir(((deltay < 0 ? 1 : 0) << 1) + (deltax > 0 ? 1 : 0))
    if mobj_movedir[actor] != turnaround
      ok = dc_kn_try_walk(actor)
      return 0 if ok != 0
    end
  end
  if dc_st_p_random(state, gx) > 200 || dc_st_abs_i(deltay) > dc_st_abs_i(deltax)
    t = d1
    d1 = d2
    d2 = t
  end
  d1 = KN_DI_NODIR if d1 == turnaround
  d2 = KN_DI_NODIR if d2 == turnaround
  if d1 != KN_DI_NODIR
    mobj_movedir[actor] = d1
    ok = dc_kn_try_walk(actor)
    return 0 if ok != 0
  end
  if d2 != KN_DI_NODIR
    mobj_movedir[actor] = d2
    ok = dc_kn_try_walk(actor)
    return 0 if ok != 0
  end
  if olddir != KN_DI_NODIR
    mobj_movedir[actor] = olddir
    ok = dc_kn_try_walk(actor)
    return 0 if ok != 0
  end
  if (dc_st_p_random(state, gx) & 1) != 0
    tdir = KN_DI_EAST
    while tdir <= KN_DI_SOUTHEAST
      if tdir != turnaround
        mobj_movedir[actor] = tdir
        ok = dc_kn_try_walk(actor)
        return 0 if ok != 0
      end
      tdir += 1
    end
  else
    tdir = KN_DI_SOUTHEAST
    while tdir != KN_DI_EAST - 1
      if tdir != turnaround
        mobj_movedir[actor] = tdir
        ok = dc_kn_try_walk(actor)
        return 0 if ok != 0
      end
      tdir -= 1
    end
  end
  if turnaround != KN_DI_NODIR
    mobj_movedir[actor] = turnaround
    ok = dc_kn_try_walk(actor)
    return 0 if ok != 0
  end
  mobj_movedir[actor] = KN_DI_NODIR
  return 0
end

# `Game#a_pos_attack`
def dc_kn_a_pos_attack(actor)
  return 0 if mobj_target[actor] < 0
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  angle = mobj_angle[actor]
  slope = dc_kn_aim_line_attack(actor, angle, KN_MISSILERANGE)
  r1 = dc_st_p_random(state, gx)
  r2 = dc_st_p_random(state, gx)
  angle = core_w32_add(angle, core_w32_mul(core_w32_sub(r1, r2), 1048576))
  damage = ((dc_st_p_random(state, gx) % 5) + 1) * 3
  dc_kn_line_attack(actor, angle, KN_MISSILERANGE, slope, damage)
  return 0
end

# `Game#a_spos_attack`
def dc_kn_a_spos_attack(actor)
  return 0 if mobj_target[actor] < 0
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  bangle = mobj_angle[actor]
  slope = dc_kn_aim_line_attack(actor, bangle, KN_MISSILERANGE)
  i = 0
  while i < 3
    r1 = dc_st_p_random(state, gx)
    r2 = dc_st_p_random(state, gx)
    angle = core_w32_add(bangle, core_w32_mul(core_w32_sub(r1, r2), 1048576))
    damage = ((dc_st_p_random(state, gx) % 5) + 1) * 3
    dc_kn_line_attack(actor, angle, KN_MISSILERANGE, slope, damage)
    i += 1
  end
  return 0
end

# `Game#a_cpos_attack`
def dc_kn_a_cpos_attack(actor)
  return 0 if mobj_target[actor] < 0
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  bangle = mobj_angle[actor]
  slope = dc_kn_aim_line_attack(actor, bangle, KN_MISSILERANGE)
  r1 = dc_st_p_random(state, gx)
  r2 = dc_st_p_random(state, gx)
  angle = core_w32_add(bangle, core_w32_mul(core_w32_sub(r1, r2), 1048576))
  damage = ((dc_st_p_random(state, gx) % 5) + 1) * 3
  dc_kn_line_attack(actor, angle, KN_MISSILERANGE, slope, damage)
  return 0
end

# `Game#a_cpos_refire`
def dc_kn_a_cpos_refire(actor)
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  return 0 if dc_st_p_random(state, gx) < 40
  tg = mobj_target[actor]
  if tg < 0 || mobj_health[tg] <= 0 || dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector,
                                                         mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y,
                                                         node_dx, node_dy, node_child0, node_child1, ss_numlines,
                                                         ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                                                         line_validcount, line_v1, line_v2, line_backsector,
                                                         line_flags, vertex_x, vertex_y, sector_floorheight,
                                                         sector_ceilingheight, sight_stack, kn_caps[KN_CAP_SIGHT],
                                                         actor, tg) == 0
    dc_kn_set_mobj_state(actor, info_seestate[mobj_type[actor]])
  end
  return 0
end

# `Game#a_spid_refire`
def dc_kn_a_spid_refire(actor)
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  return 0 if dc_st_p_random(state, gx) < 10
  tg = mobj_target[actor]
  if tg < 0 || mobj_health[tg] <= 0 || dc_st_check_sight(state, gx, reject, num_sectors, num_nodes, mobj_sector,
                                                         mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y,
                                                         node_dx, node_dy, node_child0, node_child1, ss_numlines,
                                                         ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                                                         line_validcount, line_v1, line_v2, line_backsector,
                                                         line_flags, vertex_x, vertex_y, sector_floorheight,
                                                         sector_ceilingheight, sight_stack, kn_caps[KN_CAP_SIGHT],
                                                         actor, tg) == 0
    dc_kn_set_mobj_state(actor, info_seestate[mobj_type[actor]])
  end
  return 0
end

# `Game#a_troop_attack`
def dc_kn_a_troop_attack(actor)
  tg = mobj_target[actor]
  return 0 if tg < 0
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  if dc_st_check_melee_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, info_radius,
                             mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y, node_dx, node_dy,
                             node_child0, node_child1, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                             seg_backsector, line_validcount, line_v1, line_v2, line_backsector, line_flags,
                             vertex_x, vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                             kn_caps[KN_CAP_SIGHT], actor) != 0
    damage = (dc_st_p_random(state, gx) % 8 + 1) * 3
    dc_kn_damage_mobj(tg, actor, actor, damage)
    return 0
  end
  dc_kn_spawn_missile(actor, tg, KN_MT_TROOPSHOT)
  return 0
end

# `Game#a_sarg_attack`
def dc_kn_a_sarg_attack(actor)
  tg = mobj_target[actor]
  return 0 if tg < 0
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  if dc_st_check_melee_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, info_radius,
                             mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y, node_dx, node_dy,
                             node_child0, node_child1, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                             seg_backsector, line_validcount, line_v1, line_v2, line_backsector, line_flags,
                             vertex_x, vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                             kn_caps[KN_CAP_SIGHT], actor) != 0
    damage = ((dc_st_p_random(state, gx) % 10) + 1) * 4
    dc_kn_damage_mobj(tg, actor, actor, damage)
  end
  return 0
end

# `Game#a_head_attack`
def dc_kn_a_head_attack(actor)
  tg = mobj_target[actor]
  return 0 if tg < 0
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  if dc_st_check_melee_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, info_radius,
                             mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y, node_dx, node_dy,
                             node_child0, node_child1, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                             seg_backsector, line_validcount, line_v1, line_v2, line_backsector, line_flags,
                             vertex_x, vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                             kn_caps[KN_CAP_SIGHT], actor) != 0
    damage = (dc_st_p_random(state, gx) % 6 + 1) * 10
    dc_kn_damage_mobj(tg, actor, actor, damage)
    return 0
  end
  dc_kn_spawn_missile(actor, tg, KN_MT_HEADSHOT)
  return 0
end

# `Game#a_bruis_attack`
def dc_kn_a_bruis_attack(actor)
  tg = mobj_target[actor]
  return 0 if tg < 0
  if dc_st_check_melee_range(state, gx, reject, num_sectors, num_nodes, mobj_target, mobj_type, info_radius,
                             mobj_sector, mobj_x, mobj_y, mobj_z, mobj_height, node_x, node_y, node_dx, node_dy,
                             node_child0, node_child1, ss_numlines, ss_firstline, seg_linedef, seg_frontsector,
                             seg_backsector, line_validcount, line_v1, line_v2, line_backsector, line_flags,
                             vertex_x, vertex_y, sector_floorheight, sector_ceilingheight, sight_stack,
                             kn_caps[KN_CAP_SIGHT], actor) != 0
    damage = (dc_st_p_random(state, gx) % 8 + 1) * 10
    dc_kn_damage_mobj(tg, actor, actor, damage)
    return 0
  end
  dc_kn_spawn_missile(actor, tg, KN_MT_BRUISERSHOT)
  return 0
end

# `Game#spawn_missile`: the missile's mobj
def dc_kn_spawn_missile(source, dest, type)
  th = dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth, info_reactiontime,
                        info_spawnstate, state_tics, state_sprite, state_frame, mobj_x, mobj_y, mobj_z, mobj_momx,
                        mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius, mobj_height, mobj_flags,
                        mobj_health, mobj_movedir, mobj_movecount, mobj_threshold, mobj_target, mobj_tracer,
                        mobj_player, mobj_sp_type, mobj_sp_options, mobj_reactiontime, mobj_lastlook, mobj_state,
                        mobj_tics, mobj_sprite, mobj_frame, mobj_floorz, mobj_ceilingz, mobj_subsector, mobj_sector,
                        mobj_th, thing_next, thing_prev, sector_head, mobj_bnext, mobj_bprev, blocklinks, bmaporgx,
                        bmaporgy, bmapwidth, bmapheight, num_nodes, node_x, node_y, node_dx, node_dy, node_child0,
                        node_child1, ss_sector, sector_floorheight, sector_ceilingheight, th_next, th_prev, th_func,
                        th_data, mobj_x[source], mobj_y[source], core_w32_add(mobj_z[source], core_w32_mul(core_w32_mul(4, 8), KN_FRACUNIT)),
                        type)
  mobj_target[th] = source
  an = dc_st_point_to_angle2(tantoangle, mobj_x[source], mobj_y[source], mobj_x[dest], mobj_y[dest])
  if (mobj_flags[dest] & KN_MF_SHADOW) != 0
    r1 = dc_st_p_random(state, gx)
    r2 = dc_st_p_random(state, gx)
    an = core_w32_add(an, core_w32_mul(core_w32_sub(r1, r2), 1048576))
  end
  mobj_angle[th] = an
  a = core_u32_shr(an, KN_ANGLETOFINESHIFT)
  sp = info_speed[type]
  mobj_momx[th] = core_fixed_mul(sp, finesine[a + 2048])
  mobj_momy[th] = core_fixed_mul(sp, finesine[a])
  dist = dc_st_aprox_distance(core_w32_sub(mobj_x[dest], mobj_x[source]),
                              core_w32_sub(mobj_y[dest], mobj_y[source]))
  dist = fixed_cdiv(dist, sp)
  dist = 1 if dist < 1
  mobj_momz[th] = fixed_cdiv(core_w32_sub(mobj_z[dest], mobj_z[source]), dist)
  dc_kn_check_missile_spawn(th)
  return th
end

# `Game#check_missile_spawn`
def dc_kn_check_missile_spawn(th)
  mobj_tics[th] -= dc_st_p_random(state, gx) & 3
  mobj_tics[th] = 1 if mobj_tics[th] < 1
  mobj_x[th] = core_w32_add(mobj_x[th], (mobj_momx[th] >> 1))
  mobj_y[th] = core_w32_add(mobj_y[th], (mobj_momy[th] >> 1))
  mobj_z[th] = core_w32_add(mobj_z[th], (mobj_momz[th] >> 1))
  moved = dc_kn_try_move(th, mobj_x[th], mobj_y[th])
  if moved == 0
    dc_kn_explode_missile(th)
  end
  return 0
end

# `Game#aim_line_attack`: the slope to the target found, or 0
def dc_kn_aim_line_attack(t1, angle, distance)
  a = core_u32_shr(angle, KN_ANGLETOFINESHIFT)
  state[gx[G_SHOOTTHING]] = t1
  x2 = core_w32_add(mobj_x[t1], core_w32_mul((distance >> 16), finesine[a + 2048]))
  y2 = core_w32_add(mobj_y[t1], core_w32_mul((distance >> 16), finesine[a]))
  state[gx[G_SHOOTZ]] = core_w32_add(core_w32_add(mobj_z[t1], (mobj_height[t1] >> 1)), core_w32_mul(8, KN_FRACUNIT))
  state[gx[G_TOPSLOPE]] = 100 * KN_FRACUNIT / 160
  state[gx[G_BOTTOMSLOPE]] = -(100 * KN_FRACUNIT / 160)
  state[gx[G_ATTACKRANGE]] = distance
  state[gx[G_LINETARGET]] = -1
  state[gx[G_TRAVERSER]] = 3
  dc_kn_path_traverse(mobj_x[t1], mobj_y[t1], x2, y2, 3)
  return state[gx[G_LINETARGET]] >= 0 ? state[gx[G_AIMSLOPE]] : 0
end

# `Game#line_attack`
def dc_kn_line_attack(t1, angle, distance, slope, damage)
  a = core_u32_shr(angle, KN_ANGLETOFINESHIFT)
  state[gx[G_SHOOTTHING]] = t1
  state[gx[G_LA_DAMAGE]] = damage
  x2 = core_w32_add(mobj_x[t1], core_w32_mul((distance >> 16), finesine[a + 2048]))
  y2 = core_w32_add(mobj_y[t1], core_w32_mul((distance >> 16), finesine[a]))
  state[gx[G_SHOOTZ]] = core_w32_add(core_w32_add(mobj_z[t1], (mobj_height[t1] >> 1)), core_w32_mul(8, KN_FRACUNIT))
  state[gx[G_ATTACKRANGE]] = distance
  state[gx[G_AIMSLOPE]] = slope
  state[gx[G_TRAVERSER]] = 4
  dc_kn_path_traverse(mobj_x[t1], mobj_y[t1], x2, y2, 3)
  return 0
end

# `Game#ptr_shoot_traverse`: 1 to keep going
def dc_kn_ptr_shoot_traverse(idx)
  if ic_isaline[idx] != 0
    li = ic_thing[idx]
    if line_special[li] != 0
      dc_st_shoot_special_line(line_special, mobj_player, state[gx[G_SHOOTTHING]], li)
    end
    hitline = 0
    if (line_flags[li] & KN_ML_TWOSIDED) == 0
      hitline = 1
    else
      dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                         sector_floorheight, li)
      dist = core_fixed_mul(state[gx[G_ATTACKRANGE]], ic_frac[idx])
      back = line_backsector[li]
      front = line_frontsector[li]
      if back < 0
        if core_fixed_div(core_w32_sub(state[gx[G_OPENBOTTOM]], state[gx[G_SHOOTZ]]), dist) > state[gx[G_AIMSLOPE]]
          hitline = 1
        end
        if hitline == 0 &&
           core_fixed_div(core_w32_sub(state[gx[G_OPENTOP]], state[gx[G_SHOOTZ]]), dist) < state[gx[G_AIMSLOPE]]
          hitline = 1
        end
      else
        if sector_floorheight[front] != sector_floorheight[back]
          if core_fixed_div(core_w32_sub(state[gx[G_OPENBOTTOM]], state[gx[G_SHOOTZ]]), dist) > state[gx[G_AIMSLOPE]]
            hitline = 1
          end
        end
        if hitline == 0 && sector_ceilingheight[front] != sector_ceilingheight[back]
          if core_fixed_div(core_w32_sub(state[gx[G_OPENTOP]], state[gx[G_SHOOTZ]]), dist) < state[gx[G_AIMSLOPE]]
            hitline = 1
          end
        end
      end
    end
    return 1 if hitline == 0
    frac = core_w32_sub(ic_frac[idx], core_fixed_div(4 * KN_FRACUNIT, state[gx[G_ATTACKRANGE]]))
    x = core_w32_add(state[gx[G_TRACE_X]], core_fixed_mul(state[gx[G_TRACE_DX]], frac))
    y = core_w32_add(state[gx[G_TRACE_Y]], core_fixed_mul(state[gx[G_TRACE_DY]], frac))
    z = core_w32_add(state[gx[G_SHOOTZ]], core_fixed_mul(state[gx[G_AIMSLOPE]], core_fixed_mul(frac, state[gx[G_ATTACKRANGE]])))
    front = line_frontsector[li]
    if sector_ceilingpic[front] == skyflatnum[0]
      return 0 if z > sector_ceilingheight[front]
      back = line_backsector[li]
      return 0 if back >= 0 && sector_ceilingpic[back] == skyflatnum[0]
    end
    dc_kn_spawn_puff(x, y, z, state[gx[G_ATTACKRANGE]])
    return 0
  end
  th = ic_thing[idx]
  return 1 if th == state[gx[G_SHOOTTHING]]
  return 1 if (mobj_flags[th] & KN_MF_SHOOTABLE) == 0
  dist = core_fixed_mul(state[gx[G_ATTACKRANGE]], ic_frac[idx])
  thingtopslope = core_fixed_div(core_w32_sub(core_w32_add(mobj_z[th], mobj_height[th]), state[gx[G_SHOOTZ]]), dist)
  return 1 if thingtopslope < state[gx[G_AIMSLOPE]]
  thingbottomslope = core_fixed_div(core_w32_sub(mobj_z[th], state[gx[G_SHOOTZ]]), dist)
  return 1 if thingbottomslope > state[gx[G_AIMSLOPE]]
  frac = core_w32_sub(ic_frac[idx], core_fixed_div(10 * KN_FRACUNIT, state[gx[G_ATTACKRANGE]]))
  x = core_w32_add(state[gx[G_TRACE_X]], core_fixed_mul(state[gx[G_TRACE_DX]], frac))
  y = core_w32_add(state[gx[G_TRACE_Y]], core_fixed_mul(state[gx[G_TRACE_DY]], frac))
  z = core_w32_add(state[gx[G_SHOOTZ]], core_fixed_mul(state[gx[G_AIMSLOPE]], core_fixed_mul(frac, state[gx[G_ATTACKRANGE]])))
  if (mobj_flags[th] & KN_MF_NOBLOOD) != 0
    dc_kn_spawn_puff(x, y, z, state[gx[G_ATTACKRANGE]])
  else
    dc_kn_spawn_blood(x, y, z, state[gx[G_LA_DAMAGE]])
  end
  if state[gx[G_LA_DAMAGE]] != 0
    dc_kn_damage_mobj(th, state[gx[G_SHOOTTHING]], state[gx[G_SHOOTTHING]], state[gx[G_LA_DAMAGE]])
  end
  return 0
end
