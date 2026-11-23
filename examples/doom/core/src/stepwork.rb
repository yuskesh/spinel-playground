# examples/doom/core/src/stepwork.rb — the step entry's ordinary definitions.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `inter.rb`, `specials.rb`,
# `enemy.rb`, `mapmove.rb` and `statusbar.rb` (`Doom::Game`, `Doom::StatusBar`),
# which reproduce doomgeneric's `p_*.c` and `st_stuff.c`. See ../NOTICE.md and
# ../sources.tsv.
#
# The convention is stepcore.rb's: scalar fields are core_state cells reached
# through `gx`, arrays and prepared scalars are buffers named by field, a
# boolean is 0 or 1, and `raise LevelError` is `core_fail(:capacity)`. A
# Level accessor (`lv.line_side0[l]`) is a read of that resident field. A branch
# that would end in a no-else `if` ends in `0`, because the kernel reads a
# conditional that ends a branch as that branch's value. Written
# in the port-first pass: nothing here is compared with the original yet.

G_PL_READYWEAPON = 32
G_PL_PENDINGWEAPON = 33
G_IC_N = 34
G_SB_PRIORITY = 35
G_SB_FACEINDEX = 36
G_SB_FACECOUNT = 37
G_SB_OLDHEALTH = 38
G_SB_LASTATTACKDOWN = 39
G_SB_NOTDEATHMATCH = 40
G_PL_BACKPACK = 41
G_OPENRANGE = 42
G_OPENTOP = 43
G_OPENBOTTOM = 44
G_LOWFLOOR = 45

SW_WP_FIST = 0
SW_WP_PISTOL = 1
SW_WP_SHOTGUN = 2
SW_WP_CHAINGUN = 3
SW_WP_MISSILE = 4
SW_WP_PLASMA = 5
SW_PW_INVULNERABILITY = 0
SW_PW_STRENGTH = 1
SW_PW_INVISIBILITY = 2
SW_PW_IRONFEET = 3
SW_PW_INFRARED = 5
SW_TICRATE = 35
SW_MF_SHADOW = 262144
SW_MF_AMBUSH = 32
SW_MF_NOSECTOR = 8
SW_MF_NOBLOCKMAP = 16
SW_ML_TWOSIDED = 4
SW_MAPBLOCKSHIFT = 23
SW_GLOWSPEED = 8
SW_BUTTONTIME = 35
SW_ANG45 = 536870912
SW_ANG90 = 1073741824
SW_ANG180 = -2147483648 # 2147483648, as its signed i32 pattern (decision 0022)
SW_ANG270 = -1073741824 # 3221225472, as its signed i32 pattern (decision 0022)
SW_NUMAMMO = 4
SW_NUMWEAPONS = 9
SW_MAXBUTTONS = 16
SW_MAXINTERCEPTS = 128
SW_ST_DEADFACE = 41
SW_ST_EVILGRINCOUNT = 70
SW_ST_EVILGRINOFFSET = 6
SW_ST_MUCHPAIN = 20
SW_ST_TURNCOUNT = 35
SW_ST_OUCHOFFSET = 5
SW_ST_RAMPAGEOFFSET = 7
SW_ST_TURNOFFSET = 3
SW_ST_RAMPAGEDELAY = 70
SW_ST_GODFACE = 40
SW_ST_STRAIGHTFACECOUNT = 17
SW_ATTACKER_OTHER = 2

# ------------------------------------------------------------------ angles

# `R_PointToAngle2`, the tick's own copy: `SlopeDiv(num, den)` with the larger
# as `den`, octant by octant
def dc_st_point_to_angle2(tantoangle, x1, y1, x2, y2)
  x = core_w32_sub(x2, x1)
  y = core_w32_sub(y2, y1)
  return 0 if x == 0 && y == 0
  if x >= 0
    if y >= 0
      if x > y
        dc_st_slope_to_angle(tantoangle, y, x)
      else
        core_w32_sub(core_w32_sub(SW_ANG90, 1), dc_st_slope_to_angle(tantoangle, x, y))
      end
    else
      y = core_w32_neg(y)
      if x > y
        core_w32_neg(dc_st_slope_to_angle(tantoangle, y, x))
      else
        core_w32_add(SW_ANG270, dc_st_slope_to_angle(tantoangle, x, y))
      end
    end
  else
    x = core_w32_neg(x)
    if y >= 0
      if x > y
        core_w32_sub(core_w32_sub(SW_ANG180, 1), dc_st_slope_to_angle(tantoangle, y, x))
      else
        core_w32_add(SW_ANG90, dc_st_slope_to_angle(tantoangle, x, y))
      end
    else
      y = core_w32_neg(y)
      if x > y
        core_w32_add(SW_ANG180, dc_st_slope_to_angle(tantoangle, y, x))
      else
        core_w32_sub(core_w32_sub(SW_ANG270, 1), dc_st_slope_to_angle(tantoangle, x, y))
      end
    end
  end
end

# `A_FaceTarget`
def dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  tg = mobj_target[actor]
  return 0 if tg < 0
  mobj_flags[actor] = mobj_flags[actor] & ~SW_MF_AMBUSH
  mobj_angle[actor] = dc_st_point_to_angle2(tantoangle, mobj_x[actor], mobj_y[actor], mobj_x[tg], mobj_y[tg])
  if (mobj_flags[tg] & SW_MF_SHADOW) != 0
    r1 = dc_st_p_random(state, gx)
    r2 = dc_st_p_random(state, gx)
    mobj_angle[actor] = core_w32_add(mobj_angle[actor], core_w32_mul(core_w32_sub(r1, r2), 2097152))
  end
  0
end

# ---------------------------------------------------------------- pickups

# `P_GiveAmmo`
def dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, ammo, num)
  return 0 if ammo == 5
  if ammo < 0 || ammo > 3
    core_fail(:capacity)
  end
  return 0 if pl_ammo[ammo] == pl_maxammo[ammo]
  if num != 0
    num = num * dc_st_clipammo(ammo)
  else
    num = dc_st_clipammo(ammo) / 2
  end
  num = num * 2 if skill[0] == 0 || skill[0] == 4
  oldammo = pl_ammo[ammo]
  pl_ammo[ammo] = pl_ammo[ammo] + num
  pl_ammo[ammo] = pl_maxammo[ammo] if pl_ammo[ammo] > pl_maxammo[ammo]
  return 1 if oldammo != 0
  ready = state[gx[G_PL_READYWEAPON]]
  # ammo is 0..3 here; a range tree, because the == chain became a jump table.
  # A branch of a nested if/else is typed as its value: each ends with 0.
  if ammo <= 1
    if ammo == 0
      if ready == SW_WP_FIST
        state[gx[G_PL_PENDINGWEAPON]] = pl_weaponowned[SW_WP_CHAINGUN] != 0 ? SW_WP_CHAINGUN : SW_WP_PISTOL
      end
      0
    else
      if ready == SW_WP_FIST || ready == SW_WP_PISTOL
        state[gx[G_PL_PENDINGWEAPON]] = SW_WP_SHOTGUN if pl_weaponowned[SW_WP_SHOTGUN] != 0
      end
      0
    end
  else
    if ammo == 2
      if ready == SW_WP_FIST || ready == SW_WP_PISTOL
        state[gx[G_PL_PENDINGWEAPON]] = SW_WP_PLASMA if pl_weaponowned[SW_WP_PLASMA] != 0
      end
      0
    else
      if ready == SW_WP_FIST
        state[gx[G_PL_PENDINGWEAPON]] = SW_WP_MISSILE if pl_weaponowned[SW_WP_MISSILE] != 0
      end
      0
    end
  end
  1
end

# `P_GivePower`
def dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, power)
  if power == SW_PW_INVULNERABILITY
    pl_powers[power] = 30 * SW_TICRATE
    return 1
  end
  if power == SW_PW_INVISIBILITY
    pl_powers[power] = 60 * SW_TICRATE
    mobj_flags[player_mo[0]] = mobj_flags[player_mo[0]] | SW_MF_SHADOW
    return 1
  end
  if power == SW_PW_INFRARED
    pl_powers[power] = 120 * SW_TICRATE
    return 1
  end
  if power == SW_PW_IRONFEET
    pl_powers[power] = 60 * SW_TICRATE
    return 1
  end
  if power == SW_PW_STRENGTH
    dc_st_give_body(state, gx, player_mo, mobj_health, 100)
    pl_powers[power] = 1
    return 1
  end
  return 0 if pl_powers[power] != 0
  pl_powers[power] = 1
  1
end

# `P_GiveBackpack`'s half of the backpack pickup
def dc_st_give_backpack(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned)
  if state[gx[G_PL_BACKPACK]] == 0
    i = 0
    while i < SW_NUMAMMO
      pl_maxammo[i] = pl_maxammo[i] * 2
      i += 1
    end
    state[gx[G_PL_BACKPACK]] = 1
  end
  i = 0
  while i < SW_NUMAMMO
    dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, i, 1)
    i += 1
  end
  1
end

# `P_GiveWeapon` (single player)
def dc_st_give_weapon(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, weapon_ammo, weapon, dropped)
  gaveammo = 0
  gaveweapon = 0
  if pl_weaponowned[weapon] == 0
    gaveweapon = 1
    pl_weaponowned[weapon] = 1
    state[gx[G_PL_PENDINGWEAPON]] = weapon
  end
  am = weapon_ammo[weapon]
  if am != 5
    gaveammo = dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, am, dropped != 0 ? 1 : 2)
  end
  gaveweapon != 0 || gaveammo != 0 ? 1 : 0
end

# ------------------------------------------------------------ map geometry

# `P_PointOnLineSide`
def dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, x, y, ld)
  dxl = line_dx[ld]
  dyl = line_dy[ld]
  v1 = line_v1[ld]
  if dxl == 0
    if x <= vertex_x[v1]
      return dyl > 0 ? 1 : 0
    end
    return dyl < 0 ? 1 : 0
  end
  if dyl == 0
    if y <= vertex_y[v1]
      return dxl < 0 ? 1 : 0
    end
    return dxl > 0 ? 1 : 0
  end
  dx = core_w32_sub(x, vertex_x[v1])
  dy = core_w32_sub(y, vertex_y[v1])
  left = core_fixed_mul(dyl >> 16, dx)
  right = core_fixed_mul(dy, dxl >> 16)
  right < left ? 0 : 1
end

# `P_LineOpening`
def dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                       sector_floorheight, ld)
  if line_side1[ld] == -1
    state[gx[G_OPENRANGE]] = 0
    return 0
  end
  front = line_frontsector[ld]
  back = line_backsector[ld]
  fc = sector_ceilingheight[front]
  bc = sector_ceilingheight[back]
  state[gx[G_OPENTOP]] = fc < bc ? fc : bc
  ff = sector_floorheight[front]
  bf = sector_floorheight[back]
  if ff > bf
    state[gx[G_OPENBOTTOM]] = ff
    state[gx[G_LOWFLOOR]] = bf
  else
    state[gx[G_OPENBOTTOM]] = bf
    state[gx[G_LOWFLOOR]] = ff
  end
  state[gx[G_OPENRANGE]] = core_w32_sub(state[gx[G_OPENTOP]], state[gx[G_OPENBOTTOM]])
  0
end

# `getNextSector`
def dc_st_next_sector(line_flags, line_frontsector, line_backsector, line, sec)
  return -1 if (line_flags[line] & SW_ML_TWOSIDED) == 0
  return line_backsector[line] if line_frontsector[line] == sec
  line_frontsector[line]
end

# `P_FindSectorFromLineTag`
def dc_st_find_sector_from_line_tag(num_sectors, sector_tagno, line_tagno, line, start)
  i = start + 1
  while i < num_sectors[0]
    return i if sector_tagno[i] == line_tagno[line]
    i += 1
  end
  -1
end

# `P_UnsetThingPosition`
def dc_st_unset_thing_position(mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                               mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight,
                               blocklinks, m)
  if (mobj_flags[m] & SW_MF_NOSECTOR) == 0
    n = thing_next[m]
    p = thing_prev[m]
    thing_prev[n] = p if n >= 0
    if p >= 0
      thing_next[p] = n
    else
      sector_head[mobj_sector[m]] = n
    end
  end
  if (mobj_flags[m] & SW_MF_NOBLOCKMAP) == 0
    n = mobj_bnext[m]
    p = mobj_bprev[m]
    mobj_bprev[n] = p if n >= 0
    if p >= 0
      mobj_bnext[p] = n
    else
      bx = (mobj_x[m] - bmaporgx[0]) >> SW_MAPBLOCKSHIFT
      by = (mobj_y[m] - bmaporgy[0]) >> SW_MAPBLOCKSHIFT
      if bx >= 0 && bx < bmapwidth[0] && by >= 0 && by < bmapheight[0]
        blocklinks[by * bmapwidth[0] + bx] = n
      end
      0
    end
  end
  0
end

# `PIT_AddThingIntercepts`
def dc_st_pit_add_thing_intercepts(state, gx, mobj_radius, mobj_x, mobj_y, ic_frac, ic_isaline, ic_thing, th)
  tracepositive = (state[gx[G_TRACE_DX]] ^ state[gx[G_TRACE_DY]]) > 0 ? 1 : 0
  r = mobj_radius[th]
  x1 = core_w32_sub(mobj_x[th], r)
  x2 = core_w32_add(mobj_x[th], r)
  y1 = 0
  y2 = 0
  if tracepositive != 0
    y1 = core_w32_add(mobj_y[th], r)
    y2 = core_w32_sub(mobj_y[th], r)
  else
    y1 = core_w32_sub(mobj_y[th], r)
    y2 = core_w32_add(mobj_y[th], r)
  end
  s1 = dc_st_point_on_divline_side_trace(state, gx, x1, y1)
  s2 = dc_st_point_on_divline_side_trace(state, gx, x2, y2)
  return 1 if s1 == s2
  frac = dc_st_intercept_vector(state, gx, x1, y1, core_w32_sub(x2, x1), core_w32_sub(y2, y1))
  return 1 if frac < 0
  n = state[gx[G_IC_N]]
  if n >= SW_MAXINTERCEPTS
    core_fail(:capacity)
  end
  ic_frac[n] = frac
  ic_isaline[n] = 0
  ic_thing[n] = th
  state[gx[G_IC_N]] = n + 1
  1
end

# `P_BlockThingsIterator` with PIT_AddThingIntercepts
def dc_st_block_things_iterator_addthing(state, gx, bmapwidth, bmapheight, blocklinks, mobj_bnext, mobj_radius,
                                         mobj_x, mobj_y, ic_frac, ic_isaline, ic_thing, x, y)
  return 1 if x < 0 || y < 0 || x >= bmapwidth[0] || y >= bmapheight[0]
  m = blocklinks[y * bmapwidth[0] + x]
  while m >= 0
    nxt = mobj_bnext[m]
    if dc_st_pit_add_thing_intercepts(state, gx, mobj_radius, mobj_x, mobj_y, ic_frac, ic_isaline, ic_thing, m) == 0
      return 0
    end
    m = nxt
  end
  1
end

# -------------------------------------------------------------- specials

# `P_ChangeSwitchTexture`
def dc_st_change_switch_texture(line_special, line_side0, side_toptexture, side_midtexture, side_bottomtexture,
                                switchlist, button_line, button_where, button_texture, button_timer,
                                switchlist_n, line, use_again)
  line_special[line] = 0 if use_again == 0
  sd = line_side0[line]
  textop = side_toptexture[sd]
  texmid = side_midtexture[sd]
  texbot = side_bottomtexture[sd]
  i = 0
  while i < switchlist_n
    if switchlist[i] == textop
      side_toptexture[sd] = switchlist[i ^ 1]
      if use_again != 0
        dc_st_start_button(button_line, button_where, button_texture, button_timer, line, 0, switchlist[i],
                           SW_BUTTONTIME)
      end
      return 0
    elsif switchlist[i] == texmid
      side_midtexture[sd] = switchlist[i ^ 1]
      if use_again != 0
        dc_st_start_button(button_line, button_where, button_texture, button_timer, line, 1, switchlist[i],
                           SW_BUTTONTIME)
      end
      return 0
    elsif switchlist[i] == texbot
      side_bottomtexture[sd] = switchlist[i ^ 1]
      if use_again != 0
        dc_st_start_button(button_line, button_where, button_texture, button_timer, line, 2, switchlist[i],
                           SW_BUTTONTIME)
      end
      return 0
    end
    i += 1
  end
  0
end

# `P_ShootSpecialLine`: the three gun-activated specials are not implemented in
# the original, which raises for them
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17;
# tools/doom/core-refusals.tsv): the original raises "P_ShootSpecialLine: line L
# special S not implemented" for 24, 46 and 47 (specials.rb). Reachable: special
# 46 in E1M2 (scenario shoot-46).
def dc_st_shoot_special_line(line_special, mobj_player, thing, line)
  sp = line_special[line]
  if mobj_player[thing] < 0
    return 0 unless sp == 46
  end
  if sp == 24 || sp == 46 || sp == 47
    core_fail(:capacity)
  end
  0
end

# `T_FireFlicker`
def dc_st_t_fire_flicker(state, gx, ff_count, ff_sector, ff_minlight, ff_maxlight, sector_lightlevel, k)
  ff_count[k] = ff_count[k] - 1
  return 0 if ff_count[k] != 0
  amount = (dc_st_p_random(state, gx) & 3) * 16
  sec = ff_sector[k]
  if sector_lightlevel[sec] - amount < ff_minlight[k]
    sector_lightlevel[sec] = ff_minlight[k]
  else
    sector_lightlevel[sec] = ff_maxlight[k] - amount
  end
  ff_count[k] = 4
  0
end

# `T_Glow`
def dc_st_t_glow(gl_sector, gl_direction, gl_minlight, gl_maxlight, sector_lightlevel, k)
  sec = gl_sector[k]
  if gl_direction[k] == -1
    sector_lightlevel[sec] = sector_lightlevel[sec] - SW_GLOWSPEED
    if sector_lightlevel[sec] <= gl_minlight[k]
      sector_lightlevel[sec] = sector_lightlevel[sec] + SW_GLOWSPEED
      gl_direction[k] = 1
    end
  elsif gl_direction[k] == 1
    sector_lightlevel[sec] = sector_lightlevel[sec] + SW_GLOWSPEED
    if sector_lightlevel[sec] >= gl_maxlight[k]
      sector_lightlevel[sec] = sector_lightlevel[sec] - SW_GLOWSPEED
      gl_direction[k] = -1
    end
  end
  0
end

# `T_LightFlash`
def dc_st_t_light_flash(state, gx, lf_count, lf_sector, lf_maxlight, lf_minlight, lf_mintime, lf_maxtime,
                        sector_lightlevel, k)
  lf_count[k] = lf_count[k] - 1
  return 0 if lf_count[k] != 0
  sec = lf_sector[k]
  if sector_lightlevel[sec] == lf_maxlight[k]
    sector_lightlevel[sec] = lf_minlight[k]
    lf_count[k] = (dc_st_p_random(state, gx) & lf_mintime[k]) + 1
  else
    sector_lightlevel[sec] = lf_maxlight[k]
    lf_count[k] = (dc_st_p_random(state, gx) & lf_maxtime[k]) + 1
  end
  0
end

# `T_StrobeFlash`
def dc_st_t_strobe_flash(st_count, st_sector, st_minlight, st_maxlight, st_brighttime, st_darktime,
                         sector_lightlevel, k)
  st_count[k] = st_count[k] - 1
  return 0 if st_count[k] != 0
  sec = st_sector[k]
  if sector_lightlevel[sec] == st_minlight[k]
    sector_lightlevel[sec] = st_maxlight[k]
    st_count[k] = st_brighttime[k]
  else
    sector_lightlevel[sec] = st_minlight[k]
    st_count[k] = st_darktime[k]
  end
  0
end

# `P_UpdateSpecials`: the animations, the scrolling walls, the buttons
def dc_st_update_specials(state, gx, num_anims, anim_basepic, anim_numpics, anim_speed, anim_istexture,
                          texturetranslation, flattranslation, numlinespecials, linespecials, line_side0,
                          side_textureoffset, side_toptexture, side_midtexture, side_bottomtexture,
                          button_line, button_where, button_texture, button_timer)
  dc_st_animate(num_anims, anim_basepic, anim_numpics, anim_speed, anim_istexture,
                texturetranslation, flattranslation, state[gx[G_LEVELTIME]])
  i = 0
  while i < numlinespecials[0]
    s = line_side0[linespecials[i]]
    side_textureoffset[s] = core_w32_add(side_textureoffset[s], 65536)
    i += 1
  end
  i = 0
  while i < SW_MAXBUTTONS
    if button_timer[i] != 0
      button_timer[i] = button_timer[i] - 1
      if button_timer[i] == 0
        s = line_side0[button_line[i]]
        w = button_where[i]
        if w == 0
          side_toptexture[s] = button_texture[i]
        elsif w == 1
          side_midtexture[s] = button_texture[i]
        elsif w == 2
          side_bottomtexture[s] = button_texture[i]
        end
        button_line[i] = -1
        button_where[i] = 0
        button_texture[i] = 0
      end
    end
    i += 1
  end
  0
end

# ------------------------------------------------------------ status bar

# `ST_updateFaceWidget`; `oldweaponsowned` is updated by the comparison, as vanilla writes it
def dc_st_update_face(state, gx, oldweaponsowned, weaponowned, randomnumber, health, damagecount, bonuscount,
                      attackdown, invulnerability, attacker, badguyangle, playerangle)
  if state[gx[G_SB_PRIORITY]] < 10 && health == 0
    state[gx[G_SB_PRIORITY]] = 9
    state[gx[G_SB_FACEINDEX]] = SW_ST_DEADFACE
    state[gx[G_SB_FACECOUNT]] = 1
  end
  if state[gx[G_SB_PRIORITY]] < 9 && bonuscount != 0
    doevilgrin = 0
    i = 0
    while i < SW_NUMWEAPONS
      if oldweaponsowned[i] != weaponowned[i]
        doevilgrin = 1
        oldweaponsowned[i] = weaponowned[i]
      end
      i += 1
    end
    if doevilgrin != 0
      state[gx[G_SB_PRIORITY]] = 8
      state[gx[G_SB_FACECOUNT]] = SW_ST_EVILGRINCOUNT
      state[gx[G_SB_FACEINDEX]] = dc_st_calc_pain_offset(state, gx, health) + SW_ST_EVILGRINOFFSET
    end
  end
  if state[gx[G_SB_PRIORITY]] < 8 && damagecount != 0 && attacker == SW_ATTACKER_OTHER
    state[gx[G_SB_PRIORITY]] = 7
    if health - state[gx[G_SB_OLDHEALTH]] > SW_ST_MUCHPAIN
      state[gx[G_SB_FACECOUNT]] = SW_ST_TURNCOUNT
      state[gx[G_SB_FACEINDEX]] = dc_st_calc_pain_offset(state, gx, health) + SW_ST_OUCHOFFSET
    else
      diffang = 0
      right = 0
      # angle_t, unsigned in C (decision 0022)
      if core_u32_gt(badguyangle, playerangle)
        diffang = core_w32_sub(badguyangle, playerangle)
        right = core_u32_gt(diffang, SW_ANG180) ? 1 : 0
      else
        diffang = core_w32_sub(playerangle, badguyangle)
        right = core_u32_le(diffang, SW_ANG180) ? 1 : 0
      end
      state[gx[G_SB_FACECOUNT]] = SW_ST_TURNCOUNT
      face = dc_st_calc_pain_offset(state, gx, health)
      if core_u32_lt(diffang, SW_ANG45)
        face += SW_ST_RAMPAGEOFFSET
      elsif right != 0
        face += SW_ST_TURNOFFSET
      else
        face += SW_ST_TURNOFFSET + 1
      end
      state[gx[G_SB_FACEINDEX]] = face
    end
  end
  if state[gx[G_SB_PRIORITY]] < 7 && damagecount != 0
    if health - state[gx[G_SB_OLDHEALTH]] > SW_ST_MUCHPAIN
      state[gx[G_SB_PRIORITY]] = 7
      state[gx[G_SB_FACECOUNT]] = SW_ST_TURNCOUNT
      state[gx[G_SB_FACEINDEX]] = dc_st_calc_pain_offset(state, gx, health) + SW_ST_OUCHOFFSET
    else
      state[gx[G_SB_PRIORITY]] = 6
      state[gx[G_SB_FACECOUNT]] = SW_ST_TURNCOUNT
      state[gx[G_SB_FACEINDEX]] = dc_st_calc_pain_offset(state, gx, health) + SW_ST_RAMPAGEOFFSET
    end
  end
  if state[gx[G_SB_PRIORITY]] < 6
    if attackdown != 0
      if state[gx[G_SB_LASTATTACKDOWN]] == -1
        state[gx[G_SB_LASTATTACKDOWN]] = SW_ST_RAMPAGEDELAY
      else
        state[gx[G_SB_LASTATTACKDOWN]] = state[gx[G_SB_LASTATTACKDOWN]] - 1
        if state[gx[G_SB_LASTATTACKDOWN]] == 0
          state[gx[G_SB_PRIORITY]] = 5
          state[gx[G_SB_FACEINDEX]] = dc_st_calc_pain_offset(state, gx, health) + SW_ST_RAMPAGEOFFSET
          state[gx[G_SB_FACECOUNT]] = 1
          state[gx[G_SB_LASTATTACKDOWN]] = 1
        end
        0
      end
    else
      state[gx[G_SB_LASTATTACKDOWN]] = -1
    end
  end
  if state[gx[G_SB_PRIORITY]] < 5 && invulnerability != 0
    state[gx[G_SB_PRIORITY]] = 4
    state[gx[G_SB_FACEINDEX]] = SW_ST_GODFACE
    state[gx[G_SB_FACECOUNT]] = 1
  end
  if state[gx[G_SB_FACECOUNT]] == 0
    state[gx[G_SB_FACEINDEX]] = dc_st_calc_pain_offset(state, gx, health) + (randomnumber % 3)
    state[gx[G_SB_FACECOUNT]] = SW_ST_STRAIGHTFACECOUNT
    state[gx[G_SB_PRIORITY]] = 0
  end
  state[gx[G_SB_FACECOUNT]] = state[gx[G_SB_FACECOUNT]] - 1
  0
end

# `ST_Ticker`: the key boxes, the face, and the two values the bar keeps
def dc_st_sb_ticker(state, gx, keyboxes, cards, oldweaponsowned, weaponowned, randomnumber, health, damagecount,
                    bonuscount, attackdown, invulnerability, attacker, badguyangle, playerangle)
  i = 0
  while i < 3
    keyboxes[i] = cards[i] != 0 ? i : -1
    keyboxes[i] = i + 3 if cards[i + 3] != 0
    i += 1
  end
  dc_st_update_face(state, gx, oldweaponsowned, weaponowned, randomnumber, health, damagecount, bonuscount,
                    attackdown, invulnerability, attacker, badguyangle, playerangle)
  state[gx[G_SB_NOTDEATHMATCH]] = 1
  state[gx[G_SB_OLDHEALTH]] = health
  0
end
