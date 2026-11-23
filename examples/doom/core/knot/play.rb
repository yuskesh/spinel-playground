# spinel: int64
# examples/doom/core/knot/play.rb — the step entry above the action knot, direct style.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `mapmove.rb`,
# `specials.rb`, `enemy.rb` and `pspr.rb` (`Doom::Game`), which reproduce
# doomgeneric's `g_game.c`, `p_tick.c`, `p_user.c`, `p_mobj.c`, `p_map.c`,
# `p_floor.c`, `p_plats.c`, `p_doors.c`, `p_spec.c` and `p_pspr.c`. See
# ../NOTICE.md and ../sources.tsv.
#
# NOT COMPILED. tools/doom/knot-cps.rb reads this and writes
# ../src/stepknot.rb; its header says what this source may contain. Written in
# the port-first pass: nothing here is compared with the original yet.
#
# NONE OF THESE IS RECURSIVE: they call into the knot, and are lowered with it
# so that the knot's buffers meet at one dispatcher rather than at every
# definition that reaches it. `Game#g_ticker` is the machine's root.

# `Game#thing_height_clip`: 1 when the thing still fits
def dc_kn_thing_height_clip(thing)
  onfloor = mobj_z[thing] == mobj_floorz[thing] ? 1 : 0
  dc_kn_check_position(thing, mobj_x[thing], mobj_y[thing])
  mobj_floorz[thing] = state[gx[G_TMFLOORZ]]
  mobj_ceilingz[thing] = state[gx[G_TMCEILINGZ]]
  if onfloor != 0
    mobj_z[thing] = mobj_floorz[thing]
  else
    if core_w32_add(mobj_z[thing], mobj_height[thing]) > mobj_ceilingz[thing]
      mobj_z[thing] = core_w32_sub(mobj_ceilingz[thing], mobj_height[thing])
    end
  end
  return core_w32_sub(mobj_ceilingz[thing], mobj_floorz[thing]) >= mobj_height[thing] ? 1 : 0
end

# `Game#pit_change_sector`
def dc_kn_pit_change_sector(thing)
  fits = dc_kn_thing_height_clip(thing)
  return 0 if fits != 0
  if mobj_health[thing] <= 0
    dc_kn_set_mobj_state(thing, SP_S_GIBS)
    mobj_flags[thing] &= ~SP_MF_SOLID
    mobj_height[thing] = 0
    mobj_radius[thing] = 0
    return 0
  end
  if (mobj_flags[thing] & SP_MF_DROPPED) != 0
    dc_st_remove_mobj(state, gx, mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                      mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, mobj_th,
                      th_func, th_data, thing)
    return 0
  end
  return 0 if (mobj_flags[thing] & SP_MF_SHOOTABLE) == 0
  state[gx[G_NOFIT]] = 1
  if state[gx[G_CRUSHCHANGE]] != 0 && (state[gx[G_LEVELTIME]] & 3) == 0
    dc_kn_damage_mobj(thing, -1, -1, 10)
    mo = dc_st_spawn_mobj(state, gx, skill, info_radius, info_height, info_flags, info_spawnhealth,
                          info_reactiontime, info_spawnstate, state_tics, state_sprite, state_frame, mobj_x, mobj_y,
                          mobj_z, mobj_momx, mobj_momy, mobj_momz, mobj_angle, mobj_type, mobj_radius, mobj_height,
                          mobj_flags, mobj_health, mobj_movedir, mobj_movecount, mobj_threshold, mobj_target,
                          mobj_tracer, mobj_player, mobj_sp_type, mobj_sp_options, mobj_reactiontime, mobj_lastlook,
                          mobj_state, mobj_tics, mobj_sprite, mobj_frame, mobj_floorz, mobj_ceilingz,
                          mobj_subsector, mobj_sector, mobj_th, thing_next, thing_prev, sector_head, mobj_bnext,
                          mobj_bprev, blocklinks, bmaporgx, bmaporgy, bmapwidth, bmapheight, num_nodes, node_x,
                          node_y, node_dx, node_dy, node_child0, node_child1, ss_sector, sector_floorheight,
                          sector_ceilingheight, th_next, th_prev, th_func, th_data, mobj_x[thing], mobj_y[thing],
                          core_w32_add(mobj_z[thing], mobj_height[thing] / 2), SP_MT_BLOOD)
    r1 = dc_st_p_random(state, gx)
    r2 = dc_st_p_random(state, gx)
    mobj_momx[mo] = core_w32_mul(core_w32_sub(r1, r2), 4096)
    r1 = dc_st_p_random(state, gx)
    r2 = dc_st_p_random(state, gx)
    mobj_momy[mo] = core_w32_mul(core_w32_sub(r1, r2), 4096)
  end
  0
end

# `Game#block_things_iterator_changesector`
def dc_kn_block_things_iterator_changesector(x, y)
  return 0 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  m = blocklinks[y * bmapwidth[0] + x]
  while m >= 0
    nxt = mobj_bnext[m]
    dc_kn_pit_change_sector(m)
    m = nxt
  end
  0
end

# `Game#change_sector`: 1 when something no longer fits
def dc_kn_change_sector(sec, crunch)
  state[gx[G_NOFIT]] = 0
  state[gx[G_CRUSHCHANGE]] = crunch
  x = sector_blockbox[sec * 4 + 2]
  right = sector_blockbox[sec * 4 + 3]
  while x <= right
    y = sector_blockbox[sec * 4 + 1]
    top = sector_blockbox[sec * 4]
    while y <= top
      dc_kn_block_things_iterator_changesector(x, y)
      y += 1
    end
    x += 1
  end
  return state[gx[G_NOFIT]]
end

# `Game#move_plane`: 0 ok, 1 crushed, 2 reached the destination.
# `crush` is 0 or 1.
def dc_kn_move_plane(sec, speed, dest, crush, floor_or_ceiling, direction)
  if floor_or_ceiling == 0
    if direction == -1
      if core_w32_sub(sector_floorheight[sec], speed) < dest
        lastpos = sector_floorheight[sec]
        sector_floorheight[sec] = dest
        nofit = dc_kn_change_sector(sec, crush)
        if nofit != 0
          sector_floorheight[sec] = lastpos
          dc_kn_change_sector(sec, crush)
        end
        return 2
      end
      lastpos = sector_floorheight[sec]
      sector_floorheight[sec] = core_w32_sub(lastpos, speed)
      nofit = dc_kn_change_sector(sec, crush)
      if nofit != 0
        sector_floorheight[sec] = lastpos
        dc_kn_change_sector(sec, crush)
        return 1
      end
    elsif direction == 1
      if core_w32_add(sector_floorheight[sec], speed) > dest
        lastpos = sector_floorheight[sec]
        sector_floorheight[sec] = dest
        nofit = dc_kn_change_sector(sec, crush)
        if nofit != 0
          sector_floorheight[sec] = lastpos
          dc_kn_change_sector(sec, crush)
        end
        return 2
      end
      lastpos = sector_floorheight[sec]
      sector_floorheight[sec] = core_w32_add(lastpos, speed)
      nofit = dc_kn_change_sector(sec, crush)
      if nofit != 0
        return 1 if crush != 0
        sector_floorheight[sec] = lastpos
        dc_kn_change_sector(sec, crush)
        return 1
      end
    end
  else
    if direction == -1
      if core_w32_sub(sector_ceilingheight[sec], speed) < dest
        lastpos = sector_ceilingheight[sec]
        sector_ceilingheight[sec] = dest
        nofit = dc_kn_change_sector(sec, crush)
        if nofit != 0
          sector_ceilingheight[sec] = lastpos
          dc_kn_change_sector(sec, crush)
        end
        return 2
      end
      lastpos = sector_ceilingheight[sec]
      sector_ceilingheight[sec] = core_w32_sub(lastpos, speed)
      nofit = dc_kn_change_sector(sec, crush)
      if nofit != 0
        return 1 if crush != 0
        sector_ceilingheight[sec] = lastpos
        dc_kn_change_sector(sec, crush)
        return 1
      end
    elsif direction == 1
      if core_w32_add(sector_ceilingheight[sec], speed) > dest
        lastpos = sector_ceilingheight[sec]
        sector_ceilingheight[sec] = dest
        nofit = dc_kn_change_sector(sec, crush)
        if nofit != 0
          sector_ceilingheight[sec] = lastpos
          dc_kn_change_sector(sec, crush)
        end
        return 2
      end
      sector_ceilingheight[sec] = core_w32_add(sector_ceilingheight[sec], speed)
      dc_kn_change_sector(sec, crush)
    end
  end
  0
end

# `Game#t_move_floor`
def dc_kn_t_move_floor(k)
  sec = fl_sector[k]
  res = dc_kn_move_plane(sec, fl_speed[k], fl_dest[k], fl_crush[k] != 0 ? 1 : 0, 0, fl_direction[k])
  if res == 2
    sector_specialdata[sec] = -1
    dc_st_remove_thinker(th_func, fl_th[k])
  end
  0
end

# `Game#t_plat_raise`
def dc_kn_t_plat_raise(k)
  sec = pl_sector[k]
  st = pl_status[k]
  if st == SP_PLAT_UP
    res = dc_kn_move_plane(sec, pl_speed[k], pl_high[k], pl_crush[k] != 0 ? 1 : 0, 0, 1)
    if res == 1 && pl_crush[k] == 0
      pl_count[k] = pl_wait[k]
      pl_status[k] = SP_PLAT_DOWN
    elsif res == 2
      pl_count[k] = pl_wait[k]
      pl_status[k] = SP_PLAT_WAITING
      t = pl_type[k]
      if t == SP_PT_DOWNWAITUPSTAY || t == SP_PT_RAISEANDCHANGE || t == SP_PT_RAISETONEARESTANDCHANGE
        dc_st_remove_active_plat(sector_specialdata, pl_sector, pl_th, th_func, activeplats, k)
      end
    end
  elsif st == SP_PLAT_DOWN
    res = dc_kn_move_plane(sec, pl_speed[k], pl_low[k], 0, 0, -1)
    if res == 2
      pl_count[k] = pl_wait[k]
      pl_status[k] = SP_PLAT_WAITING
    end
  elsif st == SP_PLAT_WAITING
    pl_count[k] -= 1
    if pl_count[k] == 0
      pl_status[k] = sector_floorheight[sec] == pl_low[k] ? SP_PLAT_UP : SP_PLAT_DOWN
    end
  end
  0
end

# `Game#t_vertical_door`
def dc_kn_t_vertical_door(k)
  sec = dr_sector[k]
  d = dr_direction[k]
  if d == 0
    dr_topcountdown[k] -= 1
    if dr_topcountdown[k] == 0
      dr_direction[k] = -1 if dr_type[k] == SP_VLD_NORMAL
      dr_direction[k] = 1 if dr_type[k] == SP_VLD_CLOSE30
    end
  elsif d == 2
    dr_topcountdown[k] -= 1
    if dr_topcountdown[k] == 0 && dr_type[k] == SP_VLD_RAISEIN5MINS
      dr_direction[k] = 1
      dr_type[k] = SP_VLD_NORMAL
    end
  elsif d == -1
    res = dc_kn_move_plane(sec, dr_speed[k], sector_floorheight[sec], 0, 1, -1)
    if res == 2
      if dr_type[k] == SP_VLD_NORMAL || dr_type[k] == SP_VLD_CLOSE
        sector_specialdata[sec] = -1
        dc_st_remove_thinker(th_func, dr_th[k])
      elsif dr_type[k] == SP_VLD_CLOSE30
        dr_direction[k] = 0
        dr_topcountdown[k] = SP_TICRATE * 30
      end
    elsif res == 1
      dr_direction[k] = 1 if dr_type[k] != SP_VLD_CLOSE
    end
  elsif d == 1
    res = dc_kn_move_plane(sec, dr_speed[k], dr_topheight[k], 0, 1, 1)
    if res == 2
      if dr_type[k] == SP_VLD_NORMAL
        dr_direction[k] = 0
        dr_topcountdown[k] = dr_topwait[k]
      elsif dr_type[k] == SP_VLD_CLOSE30 || dr_type[k] == SP_VLD_OPEN
        sector_specialdata[sec] = -1
        dc_st_remove_thinker(th_func, dr_th[k])
      end
    end
  end
  0
end

# `Game#stairstep`
def dc_kn_stairstep(mo)
  ok = dc_kn_try_move(mo, mobj_x[mo], core_w32_add(mobj_y[mo], mobj_momy[mo]))
  if ok == 0
    dc_kn_try_move(mo, core_w32_add(mobj_x[mo], mobj_momx[mo]), mobj_y[mo])
  end
  0
end

# `Game#slide_move`
def dc_kn_slide_move(mo)
  state[gx[G_SLIDEMO]] = mo
  hitcount = 0
  while true
    hitcount += 1
    if hitcount == 3
      dc_kn_stairstep(mo)
      return 0
    end
    if mobj_momx[mo] > 0
      leadx = core_w32_add(mobj_x[mo], mobj_radius[mo])
      trailx = core_w32_sub(mobj_x[mo], mobj_radius[mo])
    else
      leadx = core_w32_sub(mobj_x[mo], mobj_radius[mo])
      trailx = core_w32_add(mobj_x[mo], mobj_radius[mo])
    end
    if mobj_momy[mo] > 0
      leady = core_w32_add(mobj_y[mo], mobj_radius[mo])
      traily = core_w32_sub(mobj_y[mo], mobj_radius[mo])
    else
      leady = core_w32_sub(mobj_y[mo], mobj_radius[mo])
      traily = core_w32_add(mobj_y[mo], mobj_radius[mo])
    end
    state[gx[G_BESTSLIDEFRAC]] = SP_FRACUNIT + 1
    state[gx[G_TRAVERSER]] = 1
    dc_kn_path_traverse(leadx, leady, core_w32_add(leadx, mobj_momx[mo]), core_w32_add(leady, mobj_momy[mo]), 1)
    dc_kn_path_traverse(trailx, leady, core_w32_add(trailx, mobj_momx[mo]), core_w32_add(leady, mobj_momy[mo]), 1)
    dc_kn_path_traverse(leadx, traily, core_w32_add(leadx, mobj_momx[mo]), core_w32_add(traily, mobj_momy[mo]), 1)
    if state[gx[G_BESTSLIDEFRAC]] == SP_FRACUNIT + 1
      dc_kn_stairstep(mo)
      return 0
    end
    state[gx[G_BESTSLIDEFRAC]] -= 0x800
    if state[gx[G_BESTSLIDEFRAC]] > 0
      newx = core_fixed_mul(mobj_momx[mo], state[gx[G_BESTSLIDEFRAC]])
      newy = core_fixed_mul(mobj_momy[mo], state[gx[G_BESTSLIDEFRAC]])
      ok = dc_kn_try_move(mo, core_w32_add(mobj_x[mo], newx), core_w32_add(mobj_y[mo], newy))
      if ok == 0
        dc_kn_stairstep(mo)
        return 0
      end
    end
    state[gx[G_BESTSLIDEFRAC]] = core_w32_sub(SP_FRACUNIT, core_w32_add(state[gx[G_BESTSLIDEFRAC]], 0x800))
    state[gx[G_BESTSLIDEFRAC]] = SP_FRACUNIT if state[gx[G_BESTSLIDEFRAC]] > SP_FRACUNIT
    return 0 if state[gx[G_BESTSLIDEFRAC]] <= 0
    state[gx[G_TMXMOVE]] = core_fixed_mul(mobj_momx[mo], state[gx[G_BESTSLIDEFRAC]])
    state[gx[G_TMYMOVE]] = core_fixed_mul(mobj_momy[mo], state[gx[G_BESTSLIDEFRAC]])
    dc_st_hit_slide_line(state, gx, tantoangle, finesine, line_slopetype, line_dx, line_dy, line_v1, vertex_x,
                         vertex_y, mobj_x, mobj_y, state[gx[G_BESTSLIDELINE]])
    mobj_momx[mo] = state[gx[G_TMXMOVE]]
    mobj_momy[mo] = state[gx[G_TMYMOVE]]
    tx = core_w32_add(mobj_x[mo], state[gx[G_TMXMOVE]])
    ty = core_w32_add(mobj_y[mo], state[gx[G_TMYMOVE]])
    ok = dc_kn_try_move(mo, tx, ty)
    return 0 if ok != 0
  end
  0
end

# `Game#xy_movement`
def dc_kn_xy_movement(m)
  if mobj_momx[m] == 0 && mobj_momy[m] == 0
    if (mobj_flags[m] & SP_MF_SKULLFLY) != 0
      mobj_flags[m] &= ~SP_MF_SKULLFLY
      mobj_momx[m] = 0
      mobj_momy[m] = 0
      mobj_momz[m] = 0
      dc_kn_set_mobj_state(m, info_spawnstate[mobj_type[m]])
    end
    return 0
  end
  isplayer = mobj_player[m] >= 0 ? 1 : 0
  mobj_momx[m] = SP_MAXMOVE if mobj_momx[m] > SP_MAXMOVE
  mobj_momx[m] = -SP_MAXMOVE if mobj_momx[m] < -SP_MAXMOVE
  mobj_momy[m] = SP_MAXMOVE if mobj_momy[m] > SP_MAXMOVE
  mobj_momy[m] = -SP_MAXMOVE if mobj_momy[m] < -SP_MAXMOVE
  xmove = mobj_momx[m]
  ymove = mobj_momy[m]
  while true
    if xmove > SP_MAXMOVE / 2 || ymove > SP_MAXMOVE / 2
      # vanilla's `ptryx = mo->x + xmove/2` truncates toward zero; the update
      # after it, `xmove >>= 1`, floors: they differ by one on a negative odd move
      ptryx = core_w32_add(mobj_x[m], fixed_cdiv(xmove, 2))
      ptryy = core_w32_add(mobj_y[m], fixed_cdiv(ymove, 2))
      xmove >>= 1
      ymove >>= 1
    else
      ptryx = core_w32_add(mobj_x[m], xmove)
      ptryy = core_w32_add(mobj_y[m], ymove)
      xmove = 0
      ymove = 0
    end
    ok = dc_kn_try_move(m, ptryx, ptryy)
    if ok == 0
      if isplayer != 0
        dc_kn_slide_move(m)
      elsif (mobj_flags[m] & SP_MF_MISSILE) != 0
        cl = state[gx[G_CEILINGLINE]]
        if cl >= 0 && line_backsector[cl] >= 0 && sector_ceilingpic[line_backsector[cl]] == skyflatnum[0]
          dc_st_remove_mobj(state, gx, mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                            mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks,
                            mobj_th, th_func, th_data, m)
          return 0
        end
        dc_kn_explode_missile(m)
      else
        mobj_momx[m] = 0
        mobj_momy[m] = 0
      end
    end
    break if xmove == 0 && ymove == 0
  end

  return 0 if (mobj_flags[m] & (SP_MF_MISSILE | SP_MF_SKULLFLY)) != 0
  return 0 if mobj_z[m] > mobj_floorz[m]
  if (mobj_flags[m] & SP_MF_CORPSE) != 0
    if mobj_momx[m] > SP_FRACUNIT / 4 || mobj_momx[m] < -SP_FRACUNIT / 4 ||
       mobj_momy[m] > SP_FRACUNIT / 4 || mobj_momy[m] < -SP_FRACUNIT / 4
      return 0 if mobj_floorz[m] != sector_floorheight[mobj_sector[m]]
    end
  end
  if mobj_momx[m] > -SP_STOPSPEED && mobj_momx[m] < SP_STOPSPEED &&
     mobj_momy[m] > -SP_STOPSPEED && mobj_momy[m] < SP_STOPSPEED &&
     (isplayer == 0 || (state[gx[G_CMD_FORWARDMOVE]] == 0 && state[gx[G_CMD_SIDEMOVE]] == 0))
    if isplayer != 0 && (mobj_state[m] - SP_S_PLAY_RUN1) >= 0 && (mobj_state[m] - SP_S_PLAY_RUN1) < 4
      dc_kn_set_mobj_state(m, SP_S_PLAY)
    end
    mobj_momx[m] = 0
    mobj_momy[m] = 0
  else
    mobj_momx[m] = core_fixed_mul(mobj_momx[m], SP_FRICTION)
    mobj_momy[m] = core_fixed_mul(mobj_momy[m], SP_FRICTION)
  end
  0
end

# `Game#z_movement`
def dc_kn_z_movement(m)
  isplayer = mobj_player[m] >= 0 ? 1 : 0
  if isplayer != 0 && mobj_z[m] < mobj_floorz[m]
    state[gx[G_PL_VIEWHEIGHT]] = core_w32_sub(state[gx[G_PL_VIEWHEIGHT]], core_w32_sub(mobj_floorz[m], mobj_z[m]))
    state[gx[G_PL_DELTAVIEWHEIGHT]] = core_w32_sub(SP_VIEWHEIGHT, state[gx[G_PL_VIEWHEIGHT]]) >> 3
  end
  mobj_z[m] = core_w32_add(mobj_z[m], mobj_momz[m])

  if (mobj_flags[m] & SP_MF_FLOAT) != 0 && mobj_target[m] >= 0
    if (mobj_flags[m] & SP_MF_SKULLFLY) == 0 && (mobj_flags[m] & SP_MF_INFLOAT) == 0
      tg = mobj_target[m]
      dist = dc_st_aprox_distance(core_w32_sub(mobj_x[m], mobj_x[tg]), core_w32_sub(mobj_y[m], mobj_y[tg]))
      delta = core_w32_sub(core_w32_add(mobj_z[tg], (mobj_height[m] >> 1)), mobj_z[m])
      if delta < 0 && dist < -(delta * 3)
        mobj_z[m] = core_w32_sub(mobj_z[m], SP_FLOATSPEED)
      elsif delta > 0 && dist < delta * 3
        mobj_z[m] = core_w32_add(mobj_z[m], SP_FLOATSPEED)
      end
    end
  end

  if mobj_z[m] <= mobj_floorz[m]
    # gameversion >= exe_ultimate, so correct_lost_soul_bounce holds
    if (mobj_flags[m] & SP_MF_SKULLFLY) != 0
      mobj_momz[m] = core_w32_neg(mobj_momz[m])
    end
    if mobj_momz[m] < 0
      if isplayer != 0 && mobj_momz[m] < -SP_GRAVITY * 8
        state[gx[G_PL_DELTAVIEWHEIGHT]] = mobj_momz[m] >> 3
      end
      mobj_momz[m] = 0
    end
    mobj_z[m] = mobj_floorz[m]
    if (mobj_flags[m] & SP_MF_MISSILE) != 0 && (mobj_flags[m] & SP_MF_NOCLIP) == 0
      dc_kn_explode_missile(m)
      return 0
    end
  elsif (mobj_flags[m] & SP_MF_NOGRAVITY) == 0
    if mobj_momz[m] == 0
      mobj_momz[m] = -SP_GRAVITY * 2
    else
      mobj_momz[m] = core_w32_sub(mobj_momz[m], SP_GRAVITY)
    end
  end

  if core_w32_add(mobj_z[m], mobj_height[m]) > mobj_ceilingz[m]
    mobj_momz[m] = 0 if mobj_momz[m] > 0
    mobj_z[m] = core_w32_sub(mobj_ceilingz[m], mobj_height[m])
    if (mobj_flags[m] & SP_MF_SKULLFLY) != 0
      mobj_momz[m] = core_w32_neg(mobj_momz[m])
    end
    if (mobj_flags[m] & SP_MF_MISSILE) != 0 && (mobj_flags[m] & SP_MF_NOCLIP) == 0
      dc_kn_explode_missile(m)
    end
  end
  0
end

# `Game#mobj_thinker`
def dc_kn_mobj_thinker(m)
  if mobj_momx[m] != 0 || mobj_momy[m] != 0 || (mobj_flags[m] & SP_MF_SKULLFLY) != 0
    dc_kn_xy_movement(m)
    return 0 if dc_st_mobj_removed(mobj_th, th_func, m) != 0
  end
  if mobj_z[m] != mobj_floorz[m] || mobj_momz[m] != 0
    dc_kn_z_movement(m)
    return 0 if dc_st_mobj_removed(mobj_th, th_func, m) != 0
  end
  if mobj_tics[m] != -1
    mobj_tics[m] -= 1
    if mobj_tics[m] == 0
      alive = dc_kn_set_mobj_state(m, state_nextstate[mobj_state[m]])
      return 0 if alive == 0
    end
  end
  # respawnmonsters is always false here; the nightmare respawn is not reached
  0
end

# `Game#run_thinkers`
def dc_kn_run_thinkers
  t = th_next[0]
  while t != 0
    nxt = th_next[t]
    f = th_func[t]
    if f <= SP_TH_GLOW
      if f <= SP_TH_MOBJ
        if f == SP_TH_REMOVED
          th_next[th_prev[t]] = th_next[t]
          th_prev[th_next[t]] = th_prev[t]
          dc_st_free_thinker(th_func, th_data, th_prev, state, gx, t)
        else
          dc_kn_mobj_thinker(th_data[t])
        end
      else
        if f == SP_TH_LIGHTFLASH
          dc_st_t_light_flash(state, gx, lf_count, lf_sector, lf_maxlight, lf_minlight, lf_mintime, lf_maxtime,
                              sector_lightlevel, th_data[t])
        elsif f == SP_TH_STROBE
          dc_st_t_strobe_flash(st_count, st_sector, st_minlight, st_maxlight, st_brighttime, st_darktime,
                               sector_lightlevel, th_data[t])
        else
          dc_st_t_glow(gl_sector, gl_direction, gl_minlight, gl_maxlight, sector_lightlevel, th_data[t])
        end
      end
    else
      if f <= SP_TH_PLAT
        if f == SP_TH_FIREFLICKER
          dc_st_t_fire_flicker(state, gx, ff_count, ff_sector, ff_minlight, ff_maxlight, sector_lightlevel,
                               th_data[t])
        elsif f == SP_TH_DOOR
          dc_kn_t_vertical_door(th_data[t])
        else
          dc_kn_t_plat_raise(th_data[t])
        end
      else
        if f == SP_TH_FLOOR
          dc_kn_t_move_floor(th_data[t])
        elsif f == SP_TH_CEILING
          dc_st_t_move_ceiling(th_data[t])
        end
      end
    end
    t = nxt
  end
  0
end

# `Game#move_psprites`
def dc_kn_move_psprites
  i = 0
  while i < SP_NUMPSPRITES
    if psp_state[i] != 0 && psp_tics[i] != -1
      psp_tics[i] -= 1
      dc_kn_set_psprite(i, state_nextstate[psp_state[i]]) if psp_tics[i] == 0
    end
    i += 1
  end
  psp_sx[SP_PS_FLASH] = psp_sx[SP_PS_WEAPON]
  psp_sy[SP_PS_FLASH] = psp_sy[SP_PS_WEAPON]
  0
end

# `Game#death_think`
def dc_kn_death_think
  m = player_mo[0]
  dc_kn_move_psprites()
  if state[gx[G_PL_VIEWHEIGHT]] > 6 * SP_FRACUNIT
    state[gx[G_PL_VIEWHEIGHT]] -= SP_FRACUNIT
  end
  if state[gx[G_PL_VIEWHEIGHT]] < 6 * SP_FRACUNIT
    state[gx[G_PL_VIEWHEIGHT]] = 6 * SP_FRACUNIT
  end
  state[gx[G_PL_DELTAVIEWHEIGHT]] = 0
  state[gx[G_ONGROUND]] = mobj_z[m] <= mobj_floorz[m] ? 1 : 0
  dc_st_calc_height(state, gx, player_mo, mobj_momx, mobj_momy, mobj_z, mobj_ceilingz, finesine)
  at = state[gx[G_PL_ATTACKER]]
  if at >= 0 && at != m
    angle = dc_st_point_to_angle2(tantoangle, mobj_x[m], mobj_y[m], mobj_x[at], mobj_y[at])
    delta = core_w32_sub(angle, mobj_angle[m])
    ang5 = SP_ANG90 / 18
    if core_u32_lt(delta, ang5) || core_u32_gt(delta, core_w32_neg(ang5))
      mobj_angle[m] = angle
      state[gx[G_PL_DAMAGECOUNT]] -= 1 if state[gx[G_PL_DAMAGECOUNT]] != 0
    elsif core_u32_lt(delta, SP_ANG180)
      mobj_angle[m] = core_w32_add(mobj_angle[m], ang5)
    else
      mobj_angle[m] = core_w32_sub(mobj_angle[m], ang5)
    end
  elsif state[gx[G_PL_DAMAGECOUNT]] != 0
    state[gx[G_PL_DAMAGECOUNT]] -= 1
  end
  state[gx[G_PL_PLAYERSTATE]] = SP_PST_REBORN if (state[gx[G_CMD_BUTTONS]] & SP_BT_USE) != 0
  0
end

# `Game#move_player`
def dc_kn_move_player
  m = player_mo[0]
  mobj_angle[m] = core_w32_add(mobj_angle[m], core_w32_mul(state[gx[G_CMD_ANGLETURN]], 65536))
  state[gx[G_ONGROUND]] = mobj_z[m] <= mobj_floorz[m] ? 1 : 0
  if state[gx[G_CMD_FORWARDMOVE]] != 0 && state[gx[G_ONGROUND]] != 0
    dc_st_thrust(player_mo, mobj_momx, mobj_momy, finesine, mobj_angle[m], state[gx[G_CMD_FORWARDMOVE]] * 2048)
  end
  if state[gx[G_CMD_SIDEMOVE]] != 0 && state[gx[G_ONGROUND]] != 0
    dc_st_thrust(player_mo, mobj_momx, mobj_momy, finesine, core_w32_sub(mobj_angle[m], SP_ANG90),
                 state[gx[G_CMD_SIDEMOVE]] * 2048)
  end
  if (state[gx[G_CMD_FORWARDMOVE]] != 0 || state[gx[G_CMD_SIDEMOVE]] != 0) && mobj_state[m] == SP_S_PLAY
    dc_kn_set_mobj_state(m, SP_S_PLAY_RUN1)
  end
  0
end

# `Game#player_in_special_sector`: the sector specials the original implements;
# any other is what it refuses, and so is reaching E1M8's exit sector
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "E1M8 exit sector (special
# 11) reached" at low health, and "unknown sector special S" for one it does not
# handle (specials.rb). Reachable: the first, in E1M8 (scenario exit-11); the
# second is a stated limit in tools/doom/core-refusals.tsv.
def dc_kn_player_in_special_sector
  m = player_mo[0]
  sec = mobj_sector[m]
  return 0 if mobj_z[m] != sector_floorheight[sec]
  sp = sector_special[sec]
  if sp == 5
    if pl_powers[SP_PW_IRONFEET] == 0 && (state[gx[G_LEVELTIME]] & 0x1f) == 0
      dc_kn_damage_mobj(m, -1, -1, 10)
    end
  elsif sp == 7
    if pl_powers[SP_PW_IRONFEET] == 0 && (state[gx[G_LEVELTIME]] & 0x1f) == 0
      dc_kn_damage_mobj(m, -1, -1, 5)
    end
  elsif sp == 16 || sp == 4
    if pl_powers[SP_PW_IRONFEET] == 0 || dc_st_p_random(state, gx) < 5
      if (state[gx[G_LEVELTIME]] & 0x1f) == 0
        dc_kn_damage_mobj(m, -1, -1, 20)
      end
    end
  elsif sp == 9
    state[gx[G_PL_SECRETCOUNT]] += 1
    sector_special[sec] = 0
  elsif sp == 11
    if (state[gx[G_LEVELTIME]] & 0x1f) == 0
      dc_kn_damage_mobj(m, -1, -1, 20)
    end
    if state[gx[G_PL_HEALTH]] <= 10
      core_fail(:capacity)
    end
  else
    core_fail(:capacity)
  end
  0
end

# `Game#use_lines`
def dc_kn_use_lines
  m = player_mo[0]
  state[gx[G_USETHING]] = m
  a = core_u32_shr(mobj_angle[m], SP_ANGLETOFINESHIFT)
  x1 = mobj_x[m]
  y1 = mobj_y[m]
  x2 = core_w32_add(x1, core_w32_mul((SP_USERANGE >> 16), finesine[a + 2048]))
  y2 = core_w32_add(y1, core_w32_mul((SP_USERANGE >> 16), finesine[a]))
  state[gx[G_TRAVERSER]] = 2
  dc_kn_path_traverse(x1, y1, x2, y2, 1)
  0
end

# `Game#player_think`
def dc_kn_player_think
  m = player_mo[0]
  if (mobj_flags[m] & SP_MF_JUSTATTACKED) != 0
    state[gx[G_CMD_ANGLETURN]] = 0
    state[gx[G_CMD_FORWARDMOVE]] = 0xc800 / 512
    state[gx[G_CMD_SIDEMOVE]] = 0
    mobj_flags[m] &= ~SP_MF_JUSTATTACKED
  end
  if state[gx[G_PL_PLAYERSTATE]] == SP_PST_DEAD
    dc_kn_death_think()
    return 0
  end
  if mobj_reactiontime[m] != 0
    mobj_reactiontime[m] -= 1
  else
    dc_kn_move_player()
  end
  dc_st_calc_height(state, gx, player_mo, mobj_momx, mobj_momy, mobj_z, mobj_ceilingz, finesine)
  if sector_special[mobj_sector[m]] != 0
    dc_kn_player_in_special_sector()
  end

  state[gx[G_CMD_BUTTONS]] = 0 if (state[gx[G_CMD_BUTTONS]] & SP_BT_SPECIAL) != 0
  if (state[gx[G_CMD_BUTTONS]] & SP_BT_CHANGE) != 0
    newweapon = (state[gx[G_CMD_BUTTONS]] & SP_BT_WEAPONMASK) >> SP_BT_WEAPONSHIFT
    if newweapon == SP_WP_FIST && pl_weaponowned[SP_WP_CHAINSAW] != 0 &&
       !(state[gx[G_PL_READYWEAPON]] == SP_WP_CHAINSAW && pl_powers[SP_PW_STRENGTH] != 0)
      newweapon = SP_WP_CHAINSAW
    end
    if pl_weaponowned[newweapon] != 0 && newweapon != state[gx[G_PL_READYWEAPON]]
      # shareware cannot switch to the plasma rifle or the BFG
      if newweapon != SP_WP_PLASMA && newweapon != SP_WP_BFG
        state[gx[G_PL_PENDINGWEAPON]] = newweapon
      end
    end
  end

  if (state[gx[G_CMD_BUTTONS]] & SP_BT_USE) != 0
    if state[gx[G_PL_USEDOWN]] == 0
      dc_kn_use_lines()
      state[gx[G_PL_USEDOWN]] = 1
    end
  else
    state[gx[G_PL_USEDOWN]] = 0
  end

  dc_kn_move_psprites()

  pl_powers[SP_PW_STRENGTH] += 1 if pl_powers[SP_PW_STRENGTH] != 0
  pl_powers[SP_PW_INVULNERABILITY] -= 1 if pl_powers[SP_PW_INVULNERABILITY] != 0
  if pl_powers[SP_PW_INVISIBILITY] != 0
    pl_powers[SP_PW_INVISIBILITY] -= 1
    mobj_flags[m] &= ~SP_MF_SHADOW if pl_powers[SP_PW_INVISIBILITY] == 0
  end
  pl_powers[SP_PW_INFRARED] -= 1 if pl_powers[SP_PW_INFRARED] != 0
  pl_powers[SP_PW_IRONFEET] -= 1 if pl_powers[SP_PW_IRONFEET] != 0
  state[gx[G_PL_DAMAGECOUNT]] -= 1 if state[gx[G_PL_DAMAGECOUNT]] != 0
  state[gx[G_PL_BONUSCOUNT]] -= 1 if state[gx[G_PL_BONUSCOUNT]] != 0

  if pl_powers[SP_PW_INVULNERABILITY] != 0
    inv = pl_powers[SP_PW_INVULNERABILITY]
    state[gx[G_PL_FIXEDCOLORMAP]] = (inv > 4 * 32 || (inv & 8) != 0) ? 32 : 0
  elsif pl_powers[SP_PW_INFRARED] != 0
    ir = pl_powers[SP_PW_INFRARED]
    state[gx[G_PL_FIXEDCOLORMAP]] = (ir > 4 * 32 || (ir & 8) != 0) ? 1 : 0
  else
    state[gx[G_PL_FIXEDCOLORMAP]] = 0
  end
  0
end

# `Game#p_ticker`
def dc_kn_p_ticker
  dc_kn_player_think()
  dc_kn_run_thinkers()
  dc_st_update_specials(state, gx, num_anims, anim_basepic, anim_numpics, anim_speed, anim_istexture,
                        texturetranslation, flattranslation, numlinespecials, linespecials, line_side0,
                        side_textureoffset, side_toptexture, side_midtexture, side_bottomtexture, button_line,
                        button_where, button_texture, button_timer)
  # P_RespawnSpecials is deathmatch only
  state[gx[G_LEVELTIME]] += 1
  0
end

# `Game#g_ticker`: G_DoReborn is not ported, and the original refuses it
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "G_DoReborn (ga_loadlevel)
# is not implemented" when a dead player presses use (game.rb). Reachable
# (scenario reborn).
def dc_kn_g_ticker(fwd, side, aturn, buttons)
  if state[gx[G_PL_PLAYERSTATE]] == SP_PST_REBORN
    core_fail(:capacity)
  end
  state[gx[G_CMD_FORWARDMOVE]] = fwd
  state[gx[G_CMD_SIDEMOVE]] = side
  state[gx[G_CMD_ANGLETURN]] = aturn
  state[gx[G_CMD_BUTTONS]] = buttons
  dc_kn_p_ticker()
  state[gx[G_GAMETIC]] += 1
  0
end
