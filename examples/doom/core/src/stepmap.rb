# examples/doom/core/src/stepmap.rb — the step entry's map walks, pickups and sound.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `level.rb`, `mapmove.rb`,
# `sight.rb`, `specials.rb`, `inter.rb` and `enemy.rb` (`Doom::Game`,
# `Doom::Level`), which reproduce doomgeneric's `p_*.c` and `r_main.c`. See
# ../NOTICE.md and ../sources.tsv.
#
# stepcore.rb's convention. Written in the port-first pass: nothing here is
# compared with the original yet.
#
# `give_by_sprite` matches the sprite's NAME in the original; the name is a
# fixed function of the sprite number (Info.sprnames), so it is a comparison of
# numbers here, laid out as a range tree -- a dense chain is what clang turns
# into a jump table, which the link rule refuses.
#
# `recursive_sound` is the one recursive definition here. 0008 replaces it
# with a preallocated work stack: a frame is the sector, its soundblocks and
# the next line to look at, and a line that recurses pushes a frame and resumes
# the caller's loop after the pushed one returns -- the original's order. A
# sector is entered again only with a strictly smaller soundtraversed, which is
# 2 or 1, so it sits on one path at most twice: the stack holds
# 2 * numsectors frames (sound_stack, three cells a frame), and a full stack is
# CAPACITY.

G_TMBOX_TOP = 46
G_TMBOX_BOTTOM = 47
G_TMBOX_LEFT = 48
G_TMBOX_RIGHT = 49
G_VALIDCOUNT = 50
G_T2X = 51
G_T2Y = 52
G_SIGHTZSTART = 53
G_BOTTOMSLOPE = 54
G_TOPSLOPE = 55
G_TMXMOVE = 56
G_TMYMOVE = 57
G_SLIDEMO = 58
G_EARLYOUT = 59
G_ATTACKRANGE = 60
G_SHOOTZ = 61
G_SHOOTTHING = 62
G_AIMSLOPE = 63
G_LINETARGET = 64
G_BESTSLIDEFRAC = 65
G_SECONDSLIDEFRAC = 66
G_SECONDSLIDELINE = 67
G_BESTSLIDELINE = 68
G_SOUNDTARGET = 69

SM_FRACUNIT = 65536
SM_ANG180 = -2147483648 # 2147483648, as its signed i32 pattern (decision 0022)
SM_ANGLETOFINESHIFT = 19
SM_MF_SKULLFLY = 16777216
SM_MF_SHOOTABLE = 4
SM_MF_DROPPED = 131072
SM_MF_NOSECTOR = 8
SM_MF_NOBLOCKMAP = 16
SM_ML_TWOSIDED = 4
SM_ML_SOUNDBLOCK = 64
SM_MAPBLOCKSHIFT = 23
SM_MAXINTERCEPTS = 128

# ------------------------------------------------------------------ the BSP

# `Level#point_on_side`, the step's copy
def dc_st_point_on_side(node_x, node_y, node_dx, node_dy, x, y, n)
  ndx = node_dx[n]
  ndy = node_dy[n]
  if ndx == 0
    if x <= node_x[n]
      return ndy > 0 ? 1 : 0
    end
    return ndy < 0 ? 1 : 0
  end
  if ndy == 0
    if y <= node_y[n]
      return ndx < 0 ? 1 : 0
    end
    return ndx > 0 ? 1 : 0
  end
  dx = core_w32_sub(x, node_x[n])
  dy = core_w32_sub(y, node_y[n])
  neg = 0
  neg += 1 if ndy < 0
  neg += 1 if ndx < 0
  neg += 1 if dx < 0
  neg += 1 if dy < 0
  if (neg & 1) != 0
    a = ndy < 0 ? 1 : 0
    b = dx < 0 ? 1 : 0
    return a != b ? 1 : 0
  end
  left = core_fixed_mul((ndy >> 16), dx)
  right = core_fixed_mul(dy, (ndx >> 16))
  right < left ? 0 : 1
end

# `R_PointInSubsector`
def dc_st_point_in_subsector(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, x, y)
  return 0 if num_nodes[0] == 0
  nodenum = num_nodes[0] - 1
  while (nodenum & 0x8000) == 0
    side = dc_st_point_on_side(node_x, node_y, node_dx, node_dy, x, y, nodenum)
    nodenum = side == 0 ? node_child0[nodenum] : node_child1[nodenum]
  end
  nodenum & 0x7fff
end

# ------------------------------------------------------------------ things

# `P_SetThingPosition`
def dc_st_set_thing_position(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1, ss_sector,
                             mobj_x, mobj_y, mobj_flags, mobj_subsector, mobj_sector, thing_next, thing_prev,
                             sector_head, mobj_bnext, mobj_bprev, bmaporgx, bmaporgy, bmapwidth, bmapheight,
                             blocklinks, m)
  ss = dc_st_point_in_subsector(num_nodes, node_x, node_y, node_dx, node_dy, node_child0, node_child1,
                                mobj_x[m], mobj_y[m])
  mobj_subsector[m] = ss
  sec = ss_sector[ss]
  mobj_sector[m] = sec
  if (mobj_flags[m] & SM_MF_NOSECTOR) == 0
    thing_prev[m] = -1
    h = sector_head[sec]
    thing_next[m] = h
    thing_prev[h] = m if h >= 0
    sector_head[sec] = m
  end
  if (mobj_flags[m] & SM_MF_NOBLOCKMAP) == 0
    bx = (mobj_x[m] - bmaporgx[0]) >> SM_MAPBLOCKSHIFT
    by = (mobj_y[m] - bmaporgy[0]) >> SM_MAPBLOCKSHIFT
    if bx >= 0 && bx < bmapwidth[0] && by >= 0 && by < bmapheight[0]
      b = by * bmapwidth[0] + bx
      mobj_bprev[m] = -1
      h = blocklinks[b]
      mobj_bnext[m] = h
      mobj_bprev[h] = m if h >= 0
      blocklinks[b] = m
    else
      mobj_bnext[m] = -1
      mobj_bprev[m] = -1
    end
  end
  0
end

# `P_RemoveMobj`
def dc_st_remove_mobj(state, gx, mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                      mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks,
                      mobj_th, th_func, th_data, m)
  dc_st_unset_thing_position(mobj_flags, thing_next, thing_prev, sector_head, mobj_sector, mobj_bnext,
                             mobj_bprev, mobj_x, mobj_y, bmaporgx, bmaporgy, bmapwidth, bmapheight, blocklinks, m)
  dc_st_remove_thinker(th_func, mobj_th[m])
  th_data[mobj_th[m]] = -1
  dc_st_free_mobj(state, gx, thing_next, m)
  mobj_th[m] = -1
  0
end

# `A_SkullAttack`
def dc_st_a_skull_attack(state, gx, tantoangle, finesine, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y,
                         mobj_z, mobj_height, mobj_momx, mobj_momy, mobj_momz, actor)
  dest = mobj_target[actor]
  return 0 if dest < 0
  mobj_flags[actor] = mobj_flags[actor] | SM_MF_SKULLFLY
  dc_st_a_face_target(state, gx, tantoangle, mobj_target, mobj_flags, mobj_angle, mobj_x, mobj_y, actor)
  an = core_u32_shr(mobj_angle[actor], SM_ANGLETOFINESHIFT)
  skullspeed = 20 * SM_FRACUNIT
  mobj_momx[actor] = core_fixed_mul(skullspeed, finesine[an + 2048])
  mobj_momy[actor] = core_fixed_mul(skullspeed, finesine[an])
  dist = dc_st_aprox_distance(core_w32_sub(mobj_x[dest], mobj_x[actor]), core_w32_sub(mobj_y[dest], mobj_y[actor]))
  dist = fixed_cdiv(dist, skullspeed)
  dist = 1 if dist < 1
  mobj_momz[actor] = fixed_cdiv(core_w32_sub(core_w32_add(mobj_z[dest], (mobj_height[dest] >> 1)), mobj_z[actor]), dist)
  0
end

# ----------------------------------------------------------------- lines

# `P_BoxOnLineSide` against the tmbox cells
def dc_st_box_on_line_side(state, gx, line_slopetype, line_v1, line_dx, line_dy, vertex_x, vertex_y, ld)
  st = line_slopetype[ld]
  v1 = line_v1[ld]
  p1 = 0
  p2 = 0
  if st == 0
    p1 = state[gx[G_TMBOX_TOP]] > vertex_y[v1] ? 1 : 0
    p2 = state[gx[G_TMBOX_BOTTOM]] > vertex_y[v1] ? 1 : 0
    if line_dx[ld] < 0
      p1 = p1 ^ 1
      p2 = p2 ^ 1
    end
  elsif st == 1
    p1 = state[gx[G_TMBOX_RIGHT]] < vertex_x[v1] ? 1 : 0
    p2 = state[gx[G_TMBOX_LEFT]] < vertex_x[v1] ? 1 : 0
    if line_dy[ld] < 0
      p1 = p1 ^ 1
      p2 = p2 ^ 1
    end
  elsif st == 2
    p1 = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y,
                                  state[gx[G_TMBOX_LEFT]], state[gx[G_TMBOX_TOP]], ld)
    p2 = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y,
                                  state[gx[G_TMBOX_RIGHT]], state[gx[G_TMBOX_BOTTOM]], ld)
  else
    p1 = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y,
                                  state[gx[G_TMBOX_RIGHT]], state[gx[G_TMBOX_TOP]], ld)
    p2 = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y,
                                  state[gx[G_TMBOX_LEFT]], state[gx[G_TMBOX_BOTTOM]], ld)
  end
  p1 == p2 ? p1 : -1
end

# `P_HitSlideLine`
def dc_st_hit_slide_line(state, gx, tantoangle, finesine, line_slopetype, line_dx, line_dy, line_v1, vertex_x,
                         vertex_y, mobj_x, mobj_y, ld)
  st = line_slopetype[ld]
  if st == 0
    state[gx[G_TMYMOVE]] = 0
    return 0
  end
  if st == 1
    state[gx[G_TMXMOVE]] = 0
    return 0
  end
  sm = state[gx[G_SLIDEMO]]
  side = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, mobj_x[sm], mobj_y[sm], ld)
  lineangle = dc_st_point_to_angle2(tantoangle, 0, 0, line_dx[ld], line_dy[ld])
  lineangle = core_w32_add(lineangle, SM_ANG180) if side == 1
  moveangle = dc_st_point_to_angle2(tantoangle, 0, 0, state[gx[G_TMXMOVE]], state[gx[G_TMYMOVE]])
  deltaangle = core_w32_sub(moveangle, lineangle)
  deltaangle = core_w32_add(deltaangle, SM_ANG180) if core_u32_gt(deltaangle, SM_ANG180)
  la = core_u32_shr(lineangle, SM_ANGLETOFINESHIFT)
  da = core_u32_shr(deltaangle, SM_ANGLETOFINESHIFT)
  movelen = dc_st_aprox_distance(state[gx[G_TMXMOVE]], state[gx[G_TMYMOVE]])
  newlen = core_fixed_mul(movelen, finesine[da + 2048])
  state[gx[G_TMXMOVE]] = core_fixed_mul(newlen, finesine[la + 2048])
  state[gx[G_TMYMOVE]] = core_fixed_mul(newlen, finesine[la])
  0
end

# `PIT_AddLineIntercepts`
def dc_st_pit_add_line_intercepts(state, gx, line_v1, line_v2, line_dx, line_dy, line_backsector, vertex_x,
                                  vertex_y, ic_frac, ic_isaline, ic_thing, ld)
  v1 = line_v1[ld]
  v2 = line_v2[ld]
  tdx = state[gx[G_TRACE_DX]]
  tdy = state[gx[G_TRACE_DY]]
  s1 = 0
  s2 = 0
  if tdx > SM_FRACUNIT * 16 || tdy > SM_FRACUNIT * 16 || tdx < -SM_FRACUNIT * 16 || tdy < -SM_FRACUNIT * 16
    s1 = dc_st_point_on_divline_side_trace(state, gx, vertex_x[v1], vertex_y[v1])
    s2 = dc_st_point_on_divline_side_trace(state, gx, vertex_x[v2], vertex_y[v2])
  else
    tx = state[gx[G_TRACE_X]]
    ty = state[gx[G_TRACE_Y]]
    s1 = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, tx, ty, ld)
    s2 = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y,
                                  core_w32_add(tx, tdx), core_w32_add(ty, tdy), ld)
  end
  return 1 if s1 == s2
  frac = dc_st_intercept_vector(state, gx, vertex_x[v1], vertex_y[v1], line_dx[ld], line_dy[ld])
  return 1 if frac < 0
  if state[gx[G_EARLYOUT]] != 0 && frac < SM_FRACUNIT && line_backsector[ld] < 0
    return 0
  end
  n = state[gx[G_IC_N]]
  if n >= SM_MAXINTERCEPTS
    core_fail(:capacity)
  end
  ic_frac[n] = frac
  ic_isaline[n] = 1
  ic_thing[n] = ld
  state[gx[G_IC_N]] = n + 1
  1
end

# `PTR_AimTraverse`
def dc_st_ptr_aim_traverse(state, gx, line_flags, line_side1, line_frontsector, line_backsector,
                           sector_ceilingheight, sector_floorheight, ic_frac, ic_isaline, ic_thing, mobj_flags,
                           mobj_z, mobj_height, idx)
  if ic_isaline[idx] != 0
    li = ic_thing[idx]
    return 0 if (line_flags[li] & SM_ML_TWOSIDED) == 0
    dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                       sector_floorheight, li)
    return 0 if state[gx[G_OPENBOTTOM]] >= state[gx[G_OPENTOP]]
    dist = core_fixed_mul(state[gx[G_ATTACKRANGE]], ic_frac[idx])
    back = line_backsector[li]
    front = line_frontsector[li]
    if back < 0 || sector_floorheight[front] != sector_floorheight[back]
      slope = core_fixed_div(core_w32_sub(state[gx[G_OPENBOTTOM]], state[gx[G_SHOOTZ]]), dist)
      state[gx[G_BOTTOMSLOPE]] = slope if slope > state[gx[G_BOTTOMSLOPE]]
    end
    if back < 0 || sector_ceilingheight[front] != sector_ceilingheight[back]
      slope = core_fixed_div(core_w32_sub(state[gx[G_OPENTOP]], state[gx[G_SHOOTZ]]), dist)
      state[gx[G_TOPSLOPE]] = slope if slope < state[gx[G_TOPSLOPE]]
    end
    return 0 if state[gx[G_TOPSLOPE]] <= state[gx[G_BOTTOMSLOPE]]
    return 1
  end
  th = ic_thing[idx]
  return 1 if th == state[gx[G_SHOOTTHING]]
  return 1 if (mobj_flags[th] & SM_MF_SHOOTABLE) == 0
  dist = core_fixed_mul(state[gx[G_ATTACKRANGE]], ic_frac[idx])
  thingtopslope = core_fixed_div(core_w32_sub(core_w32_add(mobj_z[th], mobj_height[th]), state[gx[G_SHOOTZ]]), dist)
  return 1 if thingtopslope < state[gx[G_BOTTOMSLOPE]]
  thingbottomslope = core_fixed_div(core_w32_sub(mobj_z[th], state[gx[G_SHOOTZ]]), dist)
  return 1 if thingbottomslope > state[gx[G_TOPSLOPE]]
  thingtopslope = state[gx[G_TOPSLOPE]] if thingtopslope > state[gx[G_TOPSLOPE]]
  thingbottomslope = state[gx[G_BOTTOMSLOPE]] if thingbottomslope < state[gx[G_BOTTOMSLOPE]]
  state[gx[G_AIMSLOPE]] = fixed_cdiv(core_w32_add(thingtopslope, thingbottomslope), 2)
  state[gx[G_LINETARGET]] = th
  0
end

# `PTR_SlideTraverse`
def dc_st_ptr_slide_traverse(state, gx, line_flags, line_side1, line_frontsector, line_backsector,
                             sector_ceilingheight, sector_floorheight, line_dx, line_dy, line_v1, vertex_x,
                             vertex_y, ic_frac, ic_isaline, ic_thing, mobj_x, mobj_y, mobj_z, mobj_height, idx)
  li = ic_thing[idx]
  if ic_isaline[idx] == 0
    core_fail(:capacity)
  end
  sm = state[gx[G_SLIDEMO]]
  blocking = 0
  if (line_flags[li] & SM_ML_TWOSIDED) == 0
    if dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, mobj_x[sm], mobj_y[sm], li) != 0
      return 1
    end
    blocking = 1
  else
    dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                       sector_floorheight, li)
    if state[gx[G_OPENRANGE]] < mobj_height[sm]
      blocking = 1
    elsif core_w32_sub(state[gx[G_OPENTOP]], mobj_z[sm]) < mobj_height[sm]
      blocking = 1
    elsif core_w32_sub(state[gx[G_OPENBOTTOM]], mobj_z[sm]) > 24 * SM_FRACUNIT
      blocking = 1
    end
    0
  end
  return 1 if blocking == 0
  if ic_frac[idx] < state[gx[G_BESTSLIDEFRAC]]
    state[gx[G_SECONDSLIDEFRAC]] = state[gx[G_BESTSLIDEFRAC]]
    state[gx[G_SECONDSLIDELINE]] = state[gx[G_BESTSLIDELINE]]
    state[gx[G_BESTSLIDEFRAC]] = ic_frac[idx]
    state[gx[G_BESTSLIDELINE]] = li
  end
  0
end

# `P_CrossSubsector` (sight)
def dc_st_cross_subsector(state, gx, ss_numlines, ss_firstline, seg_linedef, seg_frontsector, seg_backsector,
                          line_validcount, line_v1, line_v2, line_backsector, line_flags, vertex_x, vertex_y,
                          sector_floorheight, sector_ceilingheight, num)
  count = ss_numlines[num]
  seg = ss_firstline[num]
  sx = state[gx[G_STRACE_X]]
  sy = state[gx[G_STRACE_Y]]
  sdx = state[gx[G_STRACE_DX]]
  sdy = state[gx[G_STRACE_DY]]
  vc = state[gx[G_VALIDCOUNT]]
  k = 0
  while k < count
    s = seg + k
    k += 1
    line = seg_linedef[s]
    next if line_validcount[line] == vc
    line_validcount[line] = vc
    v1 = line_v1[line]
    v2 = line_v2[line]
    v1x = vertex_x[v1]
    v1y = vertex_y[v1]
    v2x = vertex_x[v2]
    v2y = vertex_y[v2]
    s1 = dc_st_sight_divline_side(v1x, v1y, sx, sy, sdx, sdy)
    s2 = dc_st_sight_divline_side(v2x, v2y, sx, sy, sdx, sdy)
    next if s1 == s2
    dldx = core_w32_sub(v2x, v1x)
    dldy = core_w32_sub(v2y, v1y)
    s1 = dc_st_sight_divline_side(sx, sy, v1x, v1y, dldx, dldy)
    s2 = dc_st_sight_divline_side(state[gx[G_T2X]], state[gx[G_T2Y]], v1x, v1y, dldx, dldy)
    next if s1 == s2
    return 0 if line_backsector[line] < 0
    return 0 if (line_flags[line] & SM_ML_TWOSIDED) == 0
    front = seg_frontsector[s]
    back = seg_backsector[s]
    ff = sector_floorheight[front]
    bf = sector_floorheight[back]
    fc = sector_ceilingheight[front]
    bc = sector_ceilingheight[back]
    next if ff == bf && fc == bc
    opentop = fc < bc ? fc : bc
    openbottom = ff > bf ? ff : bf
    return 0 if openbottom >= opentop
    frac = dc_st_sight_intercept_vector(state, gx, v1x, v1y, dldx, dldy)
    if ff != bf
      slope = core_fixed_div(core_w32_sub(openbottom, state[gx[G_SIGHTZSTART]]), frac)
      state[gx[G_BOTTOMSLOPE]] = slope if slope > state[gx[G_BOTTOMSLOPE]]
    end
    if fc != bc
      slope = core_fixed_div(core_w32_sub(opentop, state[gx[G_SIGHTZSTART]]), frac)
      state[gx[G_TOPSLOPE]] = slope if slope < state[gx[G_TOPSLOPE]]
    end
    return 0 if state[gx[G_TOPSLOPE]] <= state[gx[G_BOTTOMSLOPE]]
  end
  1
end

# ------------------------------------------------------------- sectors

# `EV_LightTurnOn`
def dc_st_ev_light_turn_on(num_sectors, sector_tagno, line_tagno, sector_linecount, sector_lineofs, sector_lines,
                           sector_lightlevel, line_flags, line_frontsector, line_backsector, line, bright)
  b = bright
  i = 0
  while i < num_sectors[0]
    if sector_tagno[i] == line_tagno[line]
      if b == 0
        c = sector_linecount[i]
        o = sector_lineofs[i]
        j = 0
        while j < c
          temp = dc_st_next_sector(line_flags, line_frontsector, line_backsector, sector_lines[o + j], i)
          b = sector_lightlevel[temp] if temp >= 0 && sector_lightlevel[temp] > b
          j += 1
        end
      end
      sector_lightlevel[i] = b
    end
    i += 1
  end
  0
end

# `P_FindHighestFloorSurrounding`
def dc_st_find_highest_floor_surrounding(sector_linecount, sector_lineofs, sector_lines, sector_floorheight,
                                         line_flags, line_frontsector, line_backsector, sec)
  floor = -500 * SM_FRACUNIT
  c = sector_linecount[sec]
  o = sector_lineofs[sec]
  i = 0
  while i < c
    other = dc_st_next_sector(line_flags, line_frontsector, line_backsector, sector_lines[o + i], sec)
    floor = sector_floorheight[other] if other >= 0 && sector_floorheight[other] > floor
    i += 1
  end
  floor
end

# `P_FindLowestCeilingSurrounding`
def dc_st_find_lowest_ceiling_surrounding(sector_linecount, sector_lineofs, sector_lines, sector_ceilingheight,
                                          line_flags, line_frontsector, line_backsector, sec)
  height = 0x7fffffff
  c = sector_linecount[sec]
  o = sector_lineofs[sec]
  i = 0
  while i < c
    other = dc_st_next_sector(line_flags, line_frontsector, line_backsector, sector_lines[o + i], sec)
    if other >= 0 && sector_ceilingheight[other] < height
      height = sector_ceilingheight[other]
    end
    i += 1
  end
  height
end

# `P_FindLowestFloorSurrounding`
def dc_st_find_lowest_floor_surrounding(sector_linecount, sector_lineofs, sector_lines, sector_floorheight,
                                        line_flags, line_frontsector, line_backsector, sec)
  floor = sector_floorheight[sec]
  c = sector_linecount[sec]
  o = sector_lineofs[sec]
  i = 0
  while i < c
    other = dc_st_next_sector(line_flags, line_frontsector, line_backsector, sector_lines[o + i], sec)
    floor = sector_floorheight[other] if other >= 0 && sector_floorheight[other] < floor
    i += 1
  end
  floor
end

# `P_FindNextHighestFloor`; more than 20 higher neighbours is what the original refuses
def dc_st_find_next_highest_floor(sector_linecount, sector_lineofs, sector_lines, sector_floorheight,
                                  line_flags, line_frontsector, line_backsector, sec, currentheight)
  height = currentheight
  c = sector_linecount[sec]
  o = sector_lineofs[sec]
  h = 0
  minh = 0
  i = 0
  while i < c
    other = dc_st_next_sector(line_flags, line_frontsector, line_backsector, sector_lines[o + i], sec)
    if other >= 0 && sector_floorheight[other] > height
      if h >= 20
        core_fail(:capacity)
      end
      v = sector_floorheight[other]
      minh = v if h == 0 || v < minh
      h += 1
    end
    i += 1
  end
  h == 0 ? currentheight : minh
end

# `P_RecursiveSound`, over the preallocated stack (see the header)
def dc_st_recursive_sound(state, gx, sector_validcount, sector_soundtraversed, sector_soundtarget,
                          sector_linecount, sector_lineofs, sector_lines, line_flags, line_side0, line_side1,
                          side_sector, line_frontsector, line_backsector, sector_ceilingheight,
                          sector_floorheight, sound_stack, sound_stack_n, sec, soundblocks)
  vc = state[gx[G_VALIDCOUNT]]
  if sector_validcount[sec] == vc && sector_soundtraversed[sec] <= soundblocks + 1
    return 0
  end
  sector_validcount[sec] = vc
  sector_soundtraversed[sec] = soundblocks + 1
  sector_soundtarget[sec] = state[gx[G_SOUNDTARGET]]
  sound_stack[0] = sec
  sound_stack[1] = soundblocks
  sound_stack[2] = 0
  sp = 1
  while sp > 0
    fb = (sp - 1) * 3
    cur = sound_stack[fb]
    sb = sound_stack[fb + 1]
    i = sound_stack[fb + 2]
    c = sector_linecount[cur]
    if i >= c
      sp -= 1
      next
    end
    check = sector_lines[sector_lineofs[cur] + i]
    sound_stack[fb + 2] = i + 1
    next if (line_flags[check] & SM_ML_TWOSIDED) == 0
    dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                       sector_floorheight, check)
    next if state[gx[G_OPENRANGE]] <= 0
    s0 = side_sector[line_side0[check]]
    other = s0 == cur ? side_sector[line_side1[check]] : s0
    nsb = -1
    if (line_flags[check] & SM_ML_SOUNDBLOCK) != 0
      nsb = 1 if sb == 0
    else
      nsb = sb
    end
    next if nsb < 0
    # the call: its own entry test, then a frame
    next if sector_validcount[other] == vc && sector_soundtraversed[other] <= nsb + 1
    sector_validcount[other] = vc
    sector_soundtraversed[other] = nsb + 1
    sector_soundtarget[other] = state[gx[G_SOUNDTARGET]]
    if (sp + 1) * 3 > sound_stack_n
      core_fail(:capacity)
    end
    nb = sp * 3
    sound_stack[nb] = other
    sound_stack[nb + 1] = nsb
    sound_stack[nb + 2] = 0
    sp += 1
  end
  0
end

# ---------------------------------------------------------------- pickups

# `P_TouchSpecialThing`'s unknown gettable. AN ORIGINAL RAISE, PORTED AS
# CAPACITY (the owner's decision of 2026-09-17): the original raises for a
# pickup whose sprite it has no case for (inter.rb); CORE has no failure but
# CAPACITY. No level of the shipped IWAD places such a pickup
# (tests/doom-core/content-scan.rb).
def dc_st_unknown_gettable(spr)
  core_fail(:capacity)
  spr
end

def dc_st_sprite_bon1(state, gx, player_mo, mobj_health)
  state[gx[G_PL_MESSAGE]] = 3
  h = state[gx[G_PL_HEALTH]] + 1
  h = 200 if h > 200
  state[gx[G_PL_HEALTH]] = h
  mobj_health[player_mo[0]] = h
  1
end

def dc_st_sprite_bon2(state, gx)
  state[gx[G_PL_MESSAGE]] = 4
  a = state[gx[G_PL_ARMORPOINTS]] + 1
  a = 200 if a > 200
  state[gx[G_PL_ARMORPOINTS]] = a
  state[gx[G_PL_ARMORTYPE]] = 1 if state[gx[G_PL_ARMORTYPE]] == 0
  1
end

def dc_st_sprite_soul(state, gx, player_mo, mobj_health)
  state[gx[G_PL_MESSAGE]] = 8
  h = state[gx[G_PL_HEALTH]] + 100
  h = 200 if h > 200
  state[gx[G_PL_HEALTH]] = h
  mobj_health[player_mo[0]] = h
  1
end

def dc_st_sprite_mega(state, gx, player_mo, mobj_health)
  state[gx[G_PL_MESSAGE]] = 9
  state[gx[G_PL_HEALTH]] = 200
  mobj_health[player_mo[0]] = 200
  dc_st_give_armor(state, gx, 2)
  1
end

# GOTMEDINEED is judged after P_GiveBody added the 25, as vanilla does (so it never shows)
def dc_st_sprite_medi(state, gx, player_mo, mobj_health)
  ok = dc_st_give_body(state, gx, player_mo, mobj_health, 25)
  dc_st_msg(state, gx, ok, state[gx[G_PL_HEALTH]] < 25 ? 6 : 7)
end

# `give_by_sprite` (`P_TouchSpecialThing`'s pickup switch), by sprite number
def dc_st_give_by_sprite(state, gx, player_mo, mobj_health, mobj_flags, pl_cards, pl_powers, skill, pl_ammo,
                         pl_maxammo, pl_weaponowned, weapon_ammo, spr, special)
  dropped = (mobj_flags[special] & SM_MF_DROPPED) != 0 ? 1 : 0
  if spr <= 73
    if spr <= 65
      if spr <= 61
        if spr <= 56
          if spr <= 55
            if spr == 55
              dc_st_msg(state, gx, dc_st_give_armor(state, gx, 1), 1)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 56
              dc_st_msg(state, gx, dc_st_give_armor(state, gx, 2), 2)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 60
            if spr == 60
              dc_st_sprite_bon1(state, gx, player_mo, mobj_health)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 61
              dc_st_sprite_bon2(state, gx)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      else
        if spr <= 63
          if spr <= 62
            if spr == 62
              dc_st_msg(state, gx, dc_st_give_card(state, gx, pl_cards, 0), 10)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 63
              dc_st_msg(state, gx, dc_st_give_card(state, gx, pl_cards, 2), 12)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 64
            if spr == 64
              dc_st_msg(state, gx, dc_st_give_card(state, gx, pl_cards, 1), 11)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 65
              dc_st_msg(state, gx, dc_st_give_card(state, gx, pl_cards, 3), 13)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      end
    else
      if spr <= 69
        if spr <= 67
          if spr <= 66
            if spr == 66
              dc_st_msg(state, gx, dc_st_give_card(state, gx, pl_cards, 5), 15)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 67
              dc_st_msg(state, gx, dc_st_give_card(state, gx, pl_cards, 4), 14)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 68
            if spr == 68
              dc_st_msg(state, gx, dc_st_give_body(state, gx, player_mo, mobj_health, 10), 5)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 69
              dc_st_sprite_medi(state, gx, player_mo, mobj_health)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      else
        if spr <= 71
          if spr <= 70
            if spr == 70
              dc_st_sprite_soul(state, gx, player_mo, mobj_health)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 71
              dc_st_msg(state, gx, dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, 0), 16)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 72
            if spr == 72
              dc_st_msg(state, gx, dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, 1), 17)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 73
              dc_st_msg(state, gx, dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, 2), 18)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      end
    end
  else
    if spr <= 81
      if spr <= 77
        if spr <= 75
          if spr <= 74
            if spr == 74
              dc_st_sprite_mega(state, gx, player_mo, mobj_health)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 75
              dc_st_msg(state, gx, dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, 3), 19)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 76
            if spr == 76
              dc_st_msg(state, gx, dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, 4), 20)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 77
              dc_st_msg(state, gx, dc_st_give_power(state, gx, player_mo, pl_powers, mobj_flags, mobj_health, 5), 21)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      else
        if spr <= 79
          if spr <= 78
            if spr == 78
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 0, dropped != 0 ? 0 : 1), 22)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 79
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 0, 5), 23)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 80
            if spr == 80
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 3, 1), 24)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 81
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 3, 5), 25)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      end
    else
      if spr <= 85
        if spr <= 83
          if spr <= 82
            if spr == 82
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 2, 1), 26)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 83
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 2, 5), 27)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 84
            if spr == 84
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 1, 1), 28)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 85
              dc_st_msg(state, gx, dc_st_give_ammo(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, 1, 5), 29)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        end
      else
        if spr <= 88
          if spr <= 86
            if spr == 86
              dc_st_msg(state, gx, dc_st_give_backpack(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned), 30)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr == 88
              dc_st_msg(state, gx, dc_st_give_weapon(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, weapon_ammo, 3, dropped), 31)
            else
              dc_st_unknown_gettable(spr)
            end
          end
        else
          if spr <= 89
            if spr == 89
              dc_st_msg(state, gx, dc_st_give_weapon(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, weapon_ammo, 7, 0), 32)
            else
              dc_st_unknown_gettable(spr)
            end
          else
            if spr <= 90
              if spr == 90
                dc_st_msg(state, gx, dc_st_give_weapon(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, weapon_ammo, 4, 0), 33)
              else
                dc_st_unknown_gettable(spr)
              end
            else
              if spr == 92
                dc_st_msg(state, gx, dc_st_give_weapon(state, gx, skill, pl_ammo, pl_maxammo, pl_weaponowned, weapon_ammo, 2, dropped), 34)
              else
                dc_st_unknown_gettable(spr)
              end
            end
          end
        end
      end
    end
  end
end
