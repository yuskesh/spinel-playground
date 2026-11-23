# spinel: int64
# examples/doom/core/knot/pspr.rb — the knot's weapon actions, direct style.
#
# GPL-derived, from `examples/doom/lib/doom/pspr.rb` (`Doom::Game`), which
# reproduces doomgeneric's `p_pspr.c`. See ../NOTICE.md and ../sources.tsv.
#
# NOT COMPILED. tools/doom/knot-cps.rb reads this and writes
# ../src/stepknot.rb; its header says what this source may contain. Written in
# the port-first pass: nothing here is compared with the original yet.

# `Game#set_psprite`
def dc_kn_set_psprite(position, stnum)
  while true
    if stnum == 0
      psp_state[position] = 0
      break
    end
    psp_state[position] = stnum
    psp_tics[position] = state_tics[stnum]
    if state_misc1[stnum] != 0
      psp_sx[position] = state_misc1[stnum] << 16
      psp_sy[position] = state_misc2[stnum] << 16
    end
    a = state_action[stnum]
    if a >= 0
      dc_kn_dispatch_psp_action(a, position)
      break if psp_state[position] == 0
    end
    stnum = state_nextstate[psp_state[position]]
    break if psp_tics[position] != 0
  end
  return 0
end

# `Game#dispatch_psp_action`
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): every leaf with no action raises in the
# original, "unimplemented weapon action A" (pspr.rb). Only weapons doom1.wad
# never gives reach one: a stated limit in tools/doom/core-refusals.tsv.
def dc_kn_dispatch_psp_action(a, psp)
  # a range tree over the action ids: an == chain can become a jump table
  if a <= KN_ACT_LIGHT0
    if a <= KN_ACT_FIREMISSILE
      if a <= KN_ACT_CHECKRELOAD
        if a == KN_ACT_CHECKRELOAD
          dc_kn_check_ammo()
        else
          core_fail(:capacity)
        end
      else
        if a <= KN_ACT_FIRECGUN
          if a == KN_ACT_FIRECGUN
            dc_kn_a_fire_cgun(psp)
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_FIREMISSILE
            dc_kn_a_fire_missile(psp)
          else
            core_fail(:capacity)
          end
        end
      end
    else
      if a <= KN_ACT_FIRESHOTGUN
        if a <= KN_ACT_FIREPISTOL
          if a == KN_ACT_FIREPISTOL
            dc_kn_a_fire_pistol(psp)
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_FIRESHOTGUN
            dc_kn_a_fire_shotgun(psp)
          else
            core_fail(:capacity)
          end
        end
      else
        if a <= KN_ACT_GUNFLASH
          if a == KN_ACT_GUNFLASH
            dc_kn_a_gun_flash(psp)
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_LIGHT0
            state[gx[G_PL_EXTRALIGHT]] = 0
          else
            core_fail(:capacity)
          end
        end
      end
    end
  else
    if a <= KN_ACT_PUNCH
      if a <= KN_ACT_LIGHT2
        if a <= KN_ACT_LIGHT1
          if a == KN_ACT_LIGHT1
            state[gx[G_PL_EXTRALIGHT]] = 1
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_LIGHT2
            state[gx[G_PL_EXTRALIGHT]] = 2
          else
            core_fail(:capacity)
          end
        end
      else
        if a <= KN_ACT_LOWER
          if a == KN_ACT_LOWER
            dc_kn_a_lower(psp)
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_PUNCH
            dc_kn_a_punch(psp)
          else
            core_fail(:capacity)
          end
        end
      end
    else
      if a <= KN_ACT_REFIRE
        if a <= KN_ACT_RAISE
          if a == KN_ACT_RAISE
            dc_kn_a_raise(psp)
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_REFIRE
            dc_kn_a_refire(psp)
          else
            core_fail(:capacity)
          end
        end
      else
        if a <= KN_ACT_SAW
          if a == KN_ACT_SAW
            dc_kn_a_saw(psp)
          else
            core_fail(:capacity)
          end
        else
          if a == KN_ACT_WEAPONREADY
            dc_kn_a_weapon_ready(psp)
          else
            core_fail(:capacity)
          end
        end
      end
    end
  end
  return 0
end

# `Game#bring_up_weapon`
def dc_kn_bring_up_weapon
  if state[gx[G_PL_PENDINGWEAPON]] == KN_WP_NOCHANGE
    state[gx[G_PL_PENDINGWEAPON]] = state[gx[G_PL_READYWEAPON]]
  end
  newstate = weapon_upstate[state[gx[G_PL_PENDINGWEAPON]]]
  state[gx[G_PL_PENDINGWEAPON]] = KN_WP_NOCHANGE
  psp_sy[KN_PS_WEAPON] = KN_WEAPONBOTTOM
  dc_kn_set_psprite(KN_PS_WEAPON, newstate)
  return 0
end

# `Game#drop_weapon`
def dc_kn_drop_weapon
  dc_kn_set_psprite(KN_PS_WEAPON, weapon_downstate[state[gx[G_PL_READYWEAPON]]])
  return 0
end

# `Game#check_ammo`: 1 when the ready weapon has the ammo to fire
def dc_kn_check_ammo
  ammo = weapon_ammo[state[gx[G_PL_READYWEAPON]]]
  count = 1
  return 1 if ammo == 5 || pl_ammo[ammo] >= count
  while true
    if pl_weaponowned[KN_WP_CHAINGUN] != 0 && pl_ammo[0] != 0
      state[gx[G_PL_PENDINGWEAPON]] = KN_WP_CHAINGUN
    elsif pl_weaponowned[KN_WP_SHOTGUN] != 0 && pl_ammo[1] != 0
      state[gx[G_PL_PENDINGWEAPON]] = KN_WP_SHOTGUN
    elsif pl_ammo[0] != 0
      state[gx[G_PL_PENDINGWEAPON]] = KN_WP_PISTOL
    elsif pl_weaponowned[KN_WP_CHAINSAW] != 0
      state[gx[G_PL_PENDINGWEAPON]] = KN_WP_CHAINSAW
    elsif pl_weaponowned[KN_WP_MISSILE] != 0 && pl_ammo[3] != 0
      state[gx[G_PL_PENDINGWEAPON]] = KN_WP_MISSILE
    else
      state[gx[G_PL_PENDINGWEAPON]] = KN_WP_FIST
    end
    break if state[gx[G_PL_PENDINGWEAPON]] != KN_WP_NOCHANGE
  end
  dc_kn_set_psprite(KN_PS_WEAPON, weapon_downstate[state[gx[G_PL_READYWEAPON]]])
  return 0
end

# `Game#fire_weapon`
def dc_kn_fire_weapon
  ok = dc_kn_check_ammo()
  return 0 if ok == 0
  dc_kn_set_mobj_state(player_mo[0], KN_S_PLAY_ATK1)
  dc_kn_set_psprite(KN_PS_WEAPON, weapon_atkstate[state[gx[G_PL_READYWEAPON]]])
  dc_st_noise_alert(state, gx, mobj_sector, sector_validcount, sector_soundtraversed, sector_soundtarget,
                    sector_linecount, sector_lineofs, sector_lines, line_flags, line_side0, line_side1, side_sector,
                    line_frontsector, line_backsector, sector_ceilingheight, sector_floorheight, sound_stack,
                    kn_caps[KN_CAP_SOUND], player_mo[0], player_mo[0])
  return 0
end

# `Game#a_weapon_ready`
def dc_kn_a_weapon_ready(psp)
  m = player_mo[0]
  if mobj_state[m] == KN_S_PLAY_ATK1 || mobj_state[m] == KN_S_PLAY_ATK2
    dc_kn_set_mobj_state(m, KN_S_PLAY)
  end
  if state[gx[G_PL_PENDINGWEAPON]] != KN_WP_NOCHANGE || state[gx[G_PL_HEALTH]] == 0
    dc_kn_set_psprite(KN_PS_WEAPON, weapon_downstate[state[gx[G_PL_READYWEAPON]]])
    return 0
  end
  if (state[gx[G_CMD_BUTTONS]] & KN_BT_ATTACK) != 0
    rw = state[gx[G_PL_READYWEAPON]]
    if state[gx[G_PL_ATTACKDOWN]] == 0 || (rw != KN_WP_MISSILE && rw != KN_WP_BFG)
      state[gx[G_PL_ATTACKDOWN]] = 1
      dc_kn_fire_weapon()
      return 0
    end
  else
    state[gx[G_PL_ATTACKDOWN]] = 0
  end
  angle = (128 * state[gx[G_LEVELTIME]]) & KN_FINEMASK
  psp_sx[psp] = core_w32_add(KN_FRACUNIT, core_fixed_mul(state[gx[G_PL_BOB]], finesine[angle + 2048]))
  angle &= (KN_FINEANGLES / 2 - 1)
  psp_sy[psp] = core_w32_add(KN_WEAPONTOP, core_fixed_mul(state[gx[G_PL_BOB]], finesine[angle]))
  return 0
end

# `Game#a_refire`
def dc_kn_a_refire(psp)
  if (state[gx[G_CMD_BUTTONS]] & KN_BT_ATTACK) != 0 &&
     state[gx[G_PL_PENDINGWEAPON]] == KN_WP_NOCHANGE && state[gx[G_PL_HEALTH]] != 0
    state[gx[G_PL_REFIRE]] += 1
    dc_kn_fire_weapon()
  else
    state[gx[G_PL_REFIRE]] = 0
    dc_kn_check_ammo()
  end
  return 0
end

# `Game#a_lower`
def dc_kn_a_lower(psp)
  psp_sy[psp] = core_w32_add(psp_sy[psp], KN_LOWERSPEED)
  return 0 if psp_sy[psp] < KN_WEAPONBOTTOM
  if state[gx[G_PL_PLAYERSTATE]] == KN_PST_DEAD
    psp_sy[psp] = KN_WEAPONBOTTOM
    return 0
  end
  if state[gx[G_PL_HEALTH]] == 0
    dc_kn_set_psprite(KN_PS_WEAPON, 0)
    return 0
  end
  state[gx[G_PL_READYWEAPON]] = state[gx[G_PL_PENDINGWEAPON]]
  dc_kn_bring_up_weapon()
  return 0
end

# `Game#a_raise`
def dc_kn_a_raise(psp)
  psp_sy[psp] = core_w32_sub(psp_sy[psp], KN_RAISESPEED)
  return 0 if psp_sy[psp] > KN_WEAPONTOP
  psp_sy[psp] = KN_WEAPONTOP
  dc_kn_set_psprite(KN_PS_WEAPON, weapon_readystate[state[gx[G_PL_READYWEAPON]]])
  return 0
end

# `Game#a_gun_flash`
def dc_kn_a_gun_flash(psp)
  dc_kn_set_mobj_state(player_mo[0], KN_S_PLAY_ATK2)
  dc_kn_set_psprite(KN_PS_FLASH, weapon_flashstate[state[gx[G_PL_READYWEAPON]]])
  return 0
end

# `Game#bullet_slope`
def dc_kn_bullet_slope(mo)
  an = mobj_angle[mo]
  bs = dc_kn_aim_line_attack(mo, an, 16 * 64 * KN_FRACUNIT)
  state[gx[G_BULLETSLOPE]] = bs
  if state[gx[G_LINETARGET]] < 0
    an = core_w32_add(an, core_w32_mul(1, 67108864))
    bs = dc_kn_aim_line_attack(mo, an, 16 * 64 * KN_FRACUNIT)
    state[gx[G_BULLETSLOPE]] = bs
    if state[gx[G_LINETARGET]] < 0
      an = core_w32_sub(an, core_w32_mul(2, 67108864))
      bs = dc_kn_aim_line_attack(mo, an, 16 * 64 * KN_FRACUNIT)
      state[gx[G_BULLETSLOPE]] = bs
    end
  end
  return 0
end

# `Game#gun_shot`
def dc_kn_gun_shot(mo, accurate)
  damage = 5 * (dc_st_p_random(state, gx) % 3 + 1)
  angle = mobj_angle[mo]
  if accurate == 0
    r1 = dc_st_p_random(state, gx)
    r2 = dc_st_p_random(state, gx)
    angle = core_w32_add(angle, core_w32_mul(core_w32_sub(r1, r2), 262144))
  end
  dc_kn_line_attack(mo, angle, KN_MISSILERANGE, state[gx[G_BULLETSLOPE]], damage)
  return 0
end

# `Game#a_fire_pistol`
def dc_kn_a_fire_pistol(psp)
  m = player_mo[0]
  dc_kn_set_mobj_state(m, KN_S_PLAY_ATK2)
  dc_st_decrease_ammo(pl_ammo, pl_maxammo, weapon_ammo[state[gx[G_PL_READYWEAPON]]], 1)
  dc_kn_set_psprite(KN_PS_FLASH, weapon_flashstate[state[gx[G_PL_READYWEAPON]]])
  dc_kn_bullet_slope(m)
  dc_kn_gun_shot(m, state[gx[G_PL_REFIRE]] == 0 ? 1 : 0)
  return 0
end

# `Game#a_fire_shotgun`
def dc_kn_a_fire_shotgun(psp)
  m = player_mo[0]
  dc_kn_set_mobj_state(m, KN_S_PLAY_ATK2)
  dc_st_decrease_ammo(pl_ammo, pl_maxammo, weapon_ammo[state[gx[G_PL_READYWEAPON]]], 1)
  dc_kn_set_psprite(KN_PS_FLASH, weapon_flashstate[state[gx[G_PL_READYWEAPON]]])
  dc_kn_bullet_slope(m)
  i = 0
  while i < 7
    dc_kn_gun_shot(m, 0)
    i += 1
  end
  return 0
end

# `Game#a_fire_cgun`
def dc_kn_a_fire_cgun(psp)
  m = player_mo[0]
  return 0 if pl_ammo[weapon_ammo[state[gx[G_PL_READYWEAPON]]]] == 0
  dc_kn_set_mobj_state(m, KN_S_PLAY_ATK2)
  dc_st_decrease_ammo(pl_ammo, pl_maxammo, weapon_ammo[state[gx[G_PL_READYWEAPON]]], 1)
  dc_kn_set_psprite(KN_PS_FLASH, weapon_flashstate[state[gx[G_PL_READYWEAPON]]] + psp_state[psp] - KN_S_CHAIN1)
  dc_kn_bullet_slope(m)
  dc_kn_gun_shot(m, state[gx[G_PL_REFIRE]] == 0 ? 1 : 0)
  return 0
end

# `Game#a_punch`
def dc_kn_a_punch(psp)
  m = player_mo[0]
  damage = (dc_st_p_random(state, gx) % 10 + 1) << 1
  damage *= 10 if pl_powers[KN_PW_STRENGTH] != 0
  r1 = dc_st_p_random(state, gx)
  r2 = dc_st_p_random(state, gx)
  angle = core_w32_add(mobj_angle[m], core_w32_mul(core_w32_sub(r1, r2), 262144))
  slope = dc_kn_aim_line_attack(m, angle, KN_MELEERANGE)
  dc_kn_line_attack(m, angle, KN_MELEERANGE, slope, damage)
  lt = state[gx[G_LINETARGET]]
  if lt >= 0
    mobj_angle[m] = dc_st_point_to_angle2(tantoangle, mobj_x[m], mobj_y[m], mobj_x[lt], mobj_y[lt])
  end
  return 0
end

# `Game#a_saw`
def dc_kn_a_saw(psp)
  m = player_mo[0]
  damage = 2 * (dc_st_p_random(state, gx) % 10 + 1)
  r1 = dc_st_p_random(state, gx)
  r2 = dc_st_p_random(state, gx)
  angle = core_w32_add(mobj_angle[m], core_w32_mul(core_w32_sub(r1, r2), 262144))
  slope = dc_kn_aim_line_attack(m, angle, KN_MELEERANGE + 1)
  dc_kn_line_attack(m, angle, KN_MELEERANGE + 1, slope, damage)
  lt = state[gx[G_LINETARGET]]
  return 0 if lt < 0
  angle = dc_st_point_to_angle2(tantoangle, mobj_x[m], mobj_y[m], mobj_x[lt], mobj_y[lt])
  d = core_w32_sub(angle, mobj_angle[m])
  if core_u32_gt(d, KN_ANG180)
    # C's (signed int) cast: d is that pattern already
    if d < -(KN_ANG90 / 20)
      mobj_angle[m] = core_w32_add(angle, KN_ANG90 / 21)
    else
      mobj_angle[m] = core_w32_sub(mobj_angle[m], KN_ANG90 / 20)
    end
  else
    if core_u32_gt(d, KN_ANG90 / 20)
      mobj_angle[m] = core_w32_sub(angle, KN_ANG90 / 21)
    else
      mobj_angle[m] = core_w32_add(mobj_angle[m], KN_ANG90 / 20)
    end
  end
  mobj_flags[m] |= KN_MF_JUSTATTACKED
  return 0
end

# `Game#a_fire_missile`
def dc_kn_a_fire_missile(psp)
  dc_st_decrease_ammo(pl_ammo, pl_maxammo, weapon_ammo[state[gx[G_PL_READYWEAPON]]], 1)
  dc_kn_spawn_player_missile(player_mo[0], KN_MT_ROCKET)
  return 0
end

# `Game#spawn_player_missile`
def dc_kn_spawn_player_missile(source, type)
  an = mobj_angle[source]
  slope = dc_kn_aim_line_attack(source, an, 16 * 64 * KN_FRACUNIT)
  if state[gx[G_LINETARGET]] < 0
    an = core_w32_add(an, core_w32_mul(1, 67108864))
    slope = dc_kn_aim_line_attack(source, an, 16 * 64 * KN_FRACUNIT)
    if state[gx[G_LINETARGET]] < 0
      an = core_w32_sub(an, core_w32_mul(2, 67108864))
      slope = dc_kn_aim_line_attack(source, an, 16 * 64 * KN_FRACUNIT)
    end
    if state[gx[G_LINETARGET]] < 0
      an = mobj_angle[source]
      slope = 0
    end
  end
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
  mobj_angle[th] = an
  a = core_u32_shr(an, KN_ANGLETOFINESHIFT)
  sp = info_speed[type]
  mobj_momx[th] = core_fixed_mul(sp, finesine[a + 2048])
  mobj_momy[th] = core_fixed_mul(sp, finesine[a])
  mobj_momz[th] = core_fixed_mul(sp, slope)
  dc_kn_check_missile_spawn(th)
  return 0
end
