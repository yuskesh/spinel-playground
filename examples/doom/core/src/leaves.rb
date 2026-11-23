# examples/doom/core/src/leaves.rb — the renderer's leaf definitions.
#
# GPL-derived, from `examples/doom/lib/doom/render.rb` (`Doom::Renderer`), which
# reproduces doomgeneric's `r_main.c`, `r_segs.c`, `r_bsp.c`, `r_plane.c` and
# `r_things.c`. See ../NOTICE.md and ../sources.tsv.
#
# THE DEFINITIONS THAT CALL NO OTHER UNMIGRATED ONE (or only each other): the
# angle and distance arithmetic, the light index, the clip selector, the seg
# side test, the visplane lookup and extension, the solid-seg list's clear and
# crunch, the BSP walk's bounding-box test, the sprite sort, and the sprites'
# per-sector walk with the projection it calls. Each is reached by render code that is not ported yet, so
# the port runs beside the original AT EACH CALL, with the original's arguments,
# and its result and every cell it writes are compared there. The screen cannot
# see these: the original still computes every pixel from its own copies.
#
# ONE CLOSURE PER OPERATION. point_to_angle carries slope_div, which nothing
# else calls. find_plane and check_plane each carry their own clear_plane_top,
# and check_bbox and project_sprite their own point_to_angle and slope_div, and
# project_sprite its own light_index. FixedDiv is core_fixed_div, an intrinsic,
# which needs no copy. dup-check.rb holds every copy identical to its original,
# modulo the name.
#
# THE VALUES ARE 32-BIT DOOM VALUES, COMPUTED AT 32 BITS (decision 0022). A
# fixed-point value is a signed 32-bit one; an angle, unsigned in C, is held as
# its signed i32 bit pattern. C's wrapping arithmetic is the word intrinsics
# (core_w32_*, core_fixed_mul, core_fixed_div), and where C reads an angle as
# unsigned -- a comparison, a right shift into a table index -- the source says
# so with core_u32_*.

RL_ANG90 = 0x40000000
RL_ANG180 = -2147483648 # 0x80000000, as its signed i32 pattern (decision 0022)
RL_ANG270 = -1073741824 # 0xc0000000, likewise
RL_ANGLETOFINESHIFT = 19
RL_FRACUNIT = 65536
RL_LIGHTSCALESHIFT = 12
RL_MAXLIGHTSCALE = 48
RL_MAXVISPLANES = 128
RL_CLIP_SCREENHEIGHT = 1
RL_CLIP_NEGONE = 2
RL_MINZ = 262144 # FRACUNIT * 4
RL_MAXVISSPRITES = 128
RL_FF_FRAMEMASK = 0x7fff
RL_FF_FULLBRIGHT = 0x8000
RL_MF_TRANSLATION = 0xc000000
RL_LIGHTLEVELS = 16
RL_LIGHTSEGSHIFT = 4
# `CHECKCOORD`, the bounding-box corners to test for each of the twelve view
# positions (Doom::Renderer::CHECKCOORD), as two-bit fields, three rows to a
# 32-bit word (decision 0022: no constant past i32): rows 0-2 in W0, 3-5 in W1,
# 6-8 in W2 and 9-11 in W3, entry k of row r at bit ((r % 3) * 4 + k) * 2 of its
# word. A table in data would be a relocation the link rule refuses, and a chain
# of branches is what clang turned into one for the status bar.
RL_CHECKCOORD_W0 = 0x272363
RL_CHECKCOORD_W1 = 0x006200
RL_CHECKCOORD_W2 = 0x720037
RL_CHECKCOORD_W3 = 0x003676

# `SlopeDiv`: the tangent table's index for num/den, saturating at 2048.
def dc_slope_div(num, den)
  # C's unsigned arguments (decision 0022): den compared and shifted as a word,
  # and (num << 3) / (den >> 8) an unsigned quotient. With u = num << 3,
  # h = u >>> 1 and dd >= 2, u / dd = 2 (h / dd) + (2 (h % dd) + (u & 1)) / dd,
  # no term past i32.
  return 2048 if core_u32_lt(den, 512)
  u = core_w32_mul(num, 8)
  dd = core_u32_shr(den, 8)
  h = core_u32_shr(u, 1)
  ans = (h / dd) * 2 + ((h % dd) * 2 + (u & 1)) / dd
  ans <= 2048 ? ans : 2048
end

# `R_PointToAngle`: the angle from the view point to (px, py).
def dc_point_to_angle(state, tantoangle, i_viewx, i_viewy, px, py)
  x = core_w32_sub(px, state[i_viewx])
  y = core_w32_sub(py, state[i_viewy])
  return 0 if x == 0 && y == 0
  if x >= 0
    if y >= 0
      return tantoangle[dc_slope_div(y, x)] if x > y
      return core_w32_sub(core_w32_sub(RL_ANG90, 1), tantoangle[dc_slope_div(x, y)])
    end
    y = core_w32_neg(y)
    return core_w32_neg(tantoangle[dc_slope_div(y, x)]) if x > y
    return core_w32_add(RL_ANG270, tantoangle[dc_slope_div(x, y)])
  end
  x = core_w32_neg(x)
  if y >= 0
    return core_w32_sub(core_w32_sub(RL_ANG180, 1), tantoangle[dc_slope_div(y, x)]) if x > y
    return core_w32_add(RL_ANG90, tantoangle[dc_slope_div(x, y)])
  end
  y = core_w32_neg(y)
  return core_w32_add(RL_ANG180, tantoangle[dc_slope_div(y, x)]) if x > y
  core_w32_sub(core_w32_sub(RL_ANG270, 1), tantoangle[dc_slope_div(x, y)])
end

# `R_CheckBBox`: 1 when some part of node n's child box may be visible, 0 when
# the solid-seg list covers all of it. The original answers true or false.
def dc_check_bbox(state, node_bbox, tantoangle, clipangle, two_clipangle, viewangletox, ss_first, ss_last,
                  i_viewx, i_viewy, i_viewangle, n, child)
  b = n * 8 + child * 4
  btop = node_bbox[b]
  bbottom = node_bbox[b + 1]
  bleft = node_bbox[b + 2]
  bright = node_bbox[b + 3]
  vx = state[i_viewx]
  vy = state[i_viewy]
  boxx = vx <= bleft ? 0 : (vx < bright ? 1 : 2)
  boxy = vy >= btop ? 0 : (vy > bbottom ? 1 : 2)
  boxpos = (boxy << 2) + boxx
  return 1 if boxpos == 5
  w = boxpos / 3
  half = w == 0 ? RL_CHECKCOORD_W0 : (w == 1 ? RL_CHECKCOORD_W1 : (w == 2 ? RL_CHECKCOORD_W2 : RL_CHECKCOORD_W3))
  c = (boxpos % 3) * 4
  x1 = node_bbox[b + ((half >> (c * 2)) & 3)]
  y1 = node_bbox[b + ((half >> ((c + 1) * 2)) & 3)]
  x2 = node_bbox[b + ((half >> ((c + 2) * 2)) & 3)]
  y2 = node_bbox[b + ((half >> ((c + 3) * 2)) & 3)]
  angle1 = core_w32_sub(dc_cb_point_to_angle(state, tantoangle, i_viewx, i_viewy, x1, y1), state[i_viewangle])
  angle2 = core_w32_sub(dc_cb_point_to_angle(state, tantoangle, i_viewx, i_viewy, x2, y2), state[i_viewangle])
  span = core_w32_sub(angle1, angle2)
  return 1 if core_u32_ge(span, RL_ANG180)
  ca = clipangle[0]
  tca = two_clipangle[0]
  tspan = core_w32_add(angle1, ca)
  if core_u32_gt(tspan, tca)
    tspan = core_w32_sub(tspan, tca)
    return 0 if core_u32_ge(tspan, span)
    angle1 = ca
  end
  tspan = core_w32_sub(ca, angle2)
  if core_u32_gt(tspan, tca)
    tspan = core_w32_sub(tspan, tca)
    return 0 if core_u32_ge(tspan, span)
    angle2 = core_w32_neg(ca)
  end
  sx1 = viewangletox[core_u32_shr(core_w32_add(angle1, RL_ANG90), RL_ANGLETOFINESHIFT)]
  sx2 = viewangletox[core_u32_shr(core_w32_add(angle2, RL_ANG90), RL_ANGLETOFINESHIFT)]
  return 0 if sx1 == sx2
  sx2 -= 1
  st = 0
  while ss_last[st] < sx2
    st += 1
  end
  return 0 if sx1 >= ss_first[st] && sx2 <= ss_last[st]
  1
end

# `SlopeDiv`, check_bbox's copy.
def dc_cb_slope_div(num, den)
  # C's unsigned arguments (decision 0022): den compared and shifted as a word,
  # and (num << 3) / (den >> 8) an unsigned quotient. With u = num << 3,
  # h = u >>> 1 and dd >= 2, u / dd = 2 (h / dd) + (2 (h % dd) + (u & 1)) / dd,
  # no term past i32.
  return 2048 if core_u32_lt(den, 512)
  u = core_w32_mul(num, 8)
  dd = core_u32_shr(den, 8)
  h = core_u32_shr(u, 1)
  ans = (h / dd) * 2 + ((h % dd) * 2 + (u & 1)) / dd
  ans <= 2048 ? ans : 2048
end

# `R_PointToAngle`, check_bbox's copy.
def dc_cb_point_to_angle(state, tantoangle, i_viewx, i_viewy, px, py)
  x = core_w32_sub(px, state[i_viewx])
  y = core_w32_sub(py, state[i_viewy])
  return 0 if x == 0 && y == 0
  if x >= 0
    if y >= 0
      return tantoangle[dc_cb_slope_div(y, x)] if x > y
      return core_w32_sub(core_w32_sub(RL_ANG90, 1), tantoangle[dc_cb_slope_div(x, y)])
    end
    y = core_w32_neg(y)
    return core_w32_neg(tantoangle[dc_cb_slope_div(y, x)]) if x > y
    return core_w32_add(RL_ANG270, tantoangle[dc_cb_slope_div(x, y)])
  end
  x = core_w32_neg(x)
  if y >= 0
    return core_w32_sub(core_w32_sub(RL_ANG180, 1), tantoangle[dc_cb_slope_div(y, x)]) if x > y
    return core_w32_add(RL_ANG90, tantoangle[dc_cb_slope_div(x, y)])
  end
  y = core_w32_neg(y)
  return core_w32_add(RL_ANG180, tantoangle[dc_cb_slope_div(y, x)]) if x > y
  core_w32_sub(core_w32_sub(RL_ANG270, 1), tantoangle[dc_cb_slope_div(x, y)])
end

# `R_SortVisSprites`: vs_sorted[0..vis_n) as the sprites from farthest (smallest
# scale) to nearest, the first of equal scales first.
def dc_sort_vissprites(state, vs_scale, vs_taken, vs_sorted, i_vis_n)
  n = state[i_vis_n]
  i = 0
  while i < n
    vs_taken[i] = 0
    i += 1
  end
  k = 0
  while k < n
    best = -1
    bestscale = 0x7fffffff
    i = 0
    while i < n
      if vs_taken[i] == 0
        best = i if best < 0
        if vs_scale[i] < bestscale
          bestscale = vs_scale[i]
          best = i
        end
      end
      i += 1
    end
    vs_taken[best] = 1
    vs_sorted[k] = best
    k += 1
  end
  0
end

# `R_AddSprites`: every thing in sector sec projected, once per frame per sector,
# under the sector's light. The things' list heads and links are the GAME's,
# read through the boundary copy. project_sprite is reached only from here, so
# it is part of this closure.
def dc_add_sprites(state, sector_validcount, sector_lightlevel, sector_head, thing_next,
                   mobj_x, mobj_y, mobj_z, mobj_angle, mobj_frame, mobj_sprite, mobj_flags,
                   numframes, rotate, framebase, sprlump, sprflip, spriteoffset, spritewidth,
                   spritetopoffset, tantoangle, projection, centerxfrac, viewwidth, scalelight, resscale,
                   vs_mobjflags, vs_scale, vs_gx, vs_gy, vs_gz, vs_gzt, vs_texturemid, vs_x1, vs_x2,
                   vs_startfrac, vs_xiscale, vs_patch, vs_cmap,
                   i_validcount, i_extralight, i_viewx, i_viewy, i_viewz, i_viewcos, i_viewsin,
                   i_spritelights, i_vis_n, sec)
  return 0 if sector_validcount[sec] == state[i_validcount]
  sector_validcount[sec] = state[i_validcount]
  lightnum = (sector_lightlevel[sec] >> RL_LIGHTSEGSHIFT) + state[i_extralight]
  lightnum = 0 if lightnum < 0
  lightnum = RL_LIGHTLEVELS - 1 if lightnum >= RL_LIGHTLEVELS
  state[i_spritelights] = lightnum * RL_MAXLIGHTSCALE
  t = sector_head[sec]
  while t >= 0
    dc_project_sprite(state, mobj_x, mobj_y, mobj_z, mobj_angle, mobj_frame, mobj_sprite, mobj_flags,
                      numframes, rotate, framebase, sprlump, sprflip, spriteoffset, spritewidth,
                      spritetopoffset, tantoangle, projection, centerxfrac, viewwidth, scalelight, resscale,
                      vs_mobjflags, vs_scale, vs_gx, vs_gy, vs_gz, vs_gzt, vs_texturemid, vs_x1, vs_x2,
                      vs_startfrac, vs_xiscale, vs_patch, vs_cmap,
                      i_viewx, i_viewy, i_viewz, i_viewcos, i_viewsin, i_spritelights, i_vis_n, t)
    t = thing_next[t]
  end
  0
end

# `R_ProjectSprite`: thing's vissprite, appended when it is in front of the
# view and within the screen. The things' positions, angles, frames, sprites and
# flags are the GAME's, written by the tick and read here through the boundary
# copy; the vissprite records are the renderer's. A full table, a frame past the
# sprite's last, or a player-coloured thing -- each of which the original raises
# on -- is CAPACITY, the only refusal CORE has.
def dc_project_sprite(state, mobj_x, mobj_y, mobj_z, mobj_angle, mobj_frame, mobj_sprite, mobj_flags,
                      numframes, rotate, framebase, sprlump, sprflip, spriteoffset, spritewidth,
                      spritetopoffset, tantoangle, projection, centerxfrac, viewwidth, scalelight, resscale,
                      vs_mobjflags, vs_scale, vs_gx, vs_gy, vs_gz, vs_gzt, vs_texturemid, vs_x1, vs_x2,
                      vs_startfrac, vs_xiscale, vs_patch, vs_cmap,
                      i_viewx, i_viewy, i_viewz, i_viewcos, i_viewsin, i_spritelights, i_vis_n, thing)
  tr_x = core_w32_sub(mobj_x[thing], state[i_viewx])
  tr_y = core_w32_sub(mobj_y[thing], state[i_viewy])
  gxt = core_fixed_mul(tr_x, state[i_viewcos])
  gyt = core_fixed_mul(tr_y, state[i_viewsin])
  gyt = core_w32_neg(gyt)
  tz = core_w32_sub(gxt, gyt)
  return 0 if tz < RL_MINZ
  xscale = core_fixed_div(projection[0], tz)
  gxt = core_fixed_mul(tr_x, state[i_viewsin])
  gxt = core_w32_neg(gxt)
  gyt = core_fixed_mul(tr_y, state[i_viewcos])
  tx = core_w32_neg(core_w32_add(gyt, gxt))
  atx = tx < 0 ? -tx : tx
  return 0 if atx > (core_w32_mul(tz, 4))
  spr = mobj_sprite[thing]
  frame = mobj_frame[thing] & RL_FF_FRAMEMASK
  if frame >= numframes[spr]
    core_fail(:capacity)
  end
  fb = framebase[spr] + frame
  rot = 0
  if rotate[fb] != 0
    ang = dc_ps_point_to_angle(state, tantoangle, i_viewx, i_viewy, mobj_x[thing], mobj_y[thing])
    # (ANG45 / 2) * 9 is 0x90000000, here its signed pattern
    rot = core_u32_shr(core_w32_add(core_w32_sub(ang, mobj_angle[thing]), -1879048192), 29)
  end
  lump = sprlump[fb * 8 + rot]
  flip = sprflip[fb * 8 + rot]
  tx = core_w32_sub(tx, spriteoffset[lump])
  x1 = (core_w32_add(centerxfrac[0], core_fixed_mul(tx, xscale))) >> 16
  return 0 if x1 > viewwidth[0]
  tx = core_w32_add(tx, spritewidth[lump])
  x2 = (core_w32_add(centerxfrac[0], core_fixed_mul(tx, xscale)))
  x2 = (x2 >> 16) - 1
  return 0 if x2 < 0
  v = state[i_vis_n]
  if v == RL_MAXVISSPRITES
    core_fail(:capacity)
  end
  state[i_vis_n] = v + 1
  flags = mobj_flags[thing]
  vs_mobjflags[v] = flags
  vs_scale[v] = xscale
  vs_gx[v] = mobj_x[thing]
  vs_gy[v] = mobj_y[thing]
  vs_gz[v] = mobj_z[thing]
  gzt = core_w32_add(mobj_z[thing], spritetopoffset[lump])
  vs_gzt[v] = gzt
  vs_texturemid[v] = core_w32_sub(gzt, state[i_viewz])
  vs_x1[v] = x1 < 0 ? 0 : x1
  vs_x2[v] = x2 >= viewwidth[0] ? viewwidth[0] - 1 : x2
  iscale = core_fixed_div(RL_FRACUNIT, xscale)
  if flip != 0
    vs_startfrac[v] = spritewidth[lump] - 1
    vs_xiscale[v] = core_w32_neg(iscale)
  else
    vs_startfrac[v] = 0
    vs_xiscale[v] = iscale
  end
  if vs_x1[v] > x1
    d = core_w32_mul(vs_xiscale[v], core_w32_sub(vs_x1[v], x1))
    vs_startfrac[v] = core_w32_add(vs_startfrac[v], d)
  end
  vs_patch[v] = lump
  if (flags & RL_MF_TRANSLATION) != 0
    core_fail(:capacity)
  end
  if (mobj_frame[thing] & RL_FF_FULLBRIGHT) != 0
    vs_cmap[v] = 0
  else
    vs_cmap[v] = scalelight[state[i_spritelights] + dc_ps_light_index(resscale, xscale)]
  end
  0
end

# `SlopeDiv`, project_sprite's copy.
def dc_ps_slope_div(num, den)
  # C's unsigned arguments (decision 0022): den compared and shifted as a word,
  # and (num << 3) / (den >> 8) an unsigned quotient. With u = num << 3,
  # h = u >>> 1 and dd >= 2, u / dd = 2 (h / dd) + (2 (h % dd) + (u & 1)) / dd,
  # no term past i32.
  return 2048 if core_u32_lt(den, 512)
  u = core_w32_mul(num, 8)
  dd = core_u32_shr(den, 8)
  h = core_u32_shr(u, 1)
  ans = (h / dd) * 2 + ((h % dd) * 2 + (u & 1)) / dd
  ans <= 2048 ? ans : 2048
end

# `R_PointToAngle`, project_sprite's copy.
def dc_ps_point_to_angle(state, tantoangle, i_viewx, i_viewy, px, py)
  x = core_w32_sub(px, state[i_viewx])
  y = core_w32_sub(py, state[i_viewy])
  return 0 if x == 0 && y == 0
  if x >= 0
    if y >= 0
      return tantoangle[dc_ps_slope_div(y, x)] if x > y
      return core_w32_sub(core_w32_sub(RL_ANG90, 1), tantoangle[dc_ps_slope_div(x, y)])
    end
    y = core_w32_neg(y)
    return core_w32_neg(tantoangle[dc_ps_slope_div(y, x)]) if x > y
    return core_w32_add(RL_ANG270, tantoangle[dc_ps_slope_div(x, y)])
  end
  x = core_w32_neg(x)
  if y >= 0
    return core_w32_sub(core_w32_sub(RL_ANG180, 1), tantoangle[dc_ps_slope_div(y, x)]) if x > y
    return core_w32_add(RL_ANG90, tantoangle[dc_ps_slope_div(x, y)])
  end
  y = core_w32_neg(y)
  return core_w32_add(RL_ANG180, tantoangle[dc_ps_slope_div(y, x)]) if x > y
  core_w32_sub(core_w32_sub(RL_ANG270, 1), tantoangle[dc_ps_slope_div(x, y)])
end

# The colormap row for a scale, project_sprite's copy.
def dc_ps_light_index(resscale, scale)
  index = (scale >> RL_LIGHTSCALESHIFT) / resscale[0]
  index >= RL_MAXLIGHTSCALE ? RL_MAXLIGHTSCALE - 1 : index
end

# `R_PointToDist`: the distance from the view point to (px, py).
def dc_point_to_dist(state, tantoangle, finesine, i_viewx, i_viewy, px, py)
  dx = (core_w32_sub(px, state[i_viewx])).abs
  dy = (core_w32_sub(py, state[i_viewy])).abs
  if dy > dx
    t = dx
    dx = dy
    dy = t
  end
  frac = dx != 0 ? core_fixed_div(dy, dx) : 0
  angle = core_u32_shr(core_w32_add(tantoangle[frac >> 5], RL_ANG90), RL_ANGLETOFINESHIFT)
  core_fixed_div(dx, finesine[angle])
end

# `R_ScaleFromGlobalAngle`: the wall scale at one screen column's angle.
def dc_scale_from_global_angle(state, finesine, projection, i_viewangle, i_rw_normalangle, i_rw_distance,
                               visangle)
  anglea = core_w32_add(RL_ANG90, (core_w32_sub(visangle, state[i_viewangle])))
  angleb = core_w32_add(RL_ANG90, (core_w32_sub(visangle, state[i_rw_normalangle])))
  sinea = finesine[core_u32_shr(anglea, RL_ANGLETOFINESHIFT)]
  sineb = finesine[core_u32_shr(angleb, RL_ANGLETOFINESHIFT)]
  num = core_fixed_mul(projection[0], sineb)
  den = core_fixed_mul(state[i_rw_distance], sinea)
  return 64 * RL_FRACUNIT unless den > (num >> 16)
  scale = core_fixed_div(num, den)
  return 64 * RL_FRACUNIT if scale > 64 * RL_FRACUNIT
  return 256 if scale < 256
  scale
end

# The colormap row for a scale, clamped to the last one.
def dc_light_index(resscale, scale)
  index = (scale >> RL_LIGHTSCALESHIFT) / resscale[0]
  index >= RL_MAXLIGHTSCALE ? RL_MAXLIGHTSCALE - 1 : index
end

# An angle's distance from 0 either way round.
def dc_abs_angle(u)
  # 2**32 - u for a word at or past ANG180, which is its negation
  core_u32_ge(u, RL_ANG180) ? core_w32_neg(u) : u
end

# A sprite clip bound: the screen's height, -1, or an openings cell.
def dc_clip_value(openings, viewheight, kind, base, x)
  return viewheight[0] if kind == RL_CLIP_SCREENHEIGHT
  return -1 if kind == RL_CLIP_NEGONE
  openings[base + x]
end

# `R_PointOnSegSide`: 0 for the front of the seg, 1 for the back.
def dc_point_on_seg_side(vertex_x, vertex_y, seg_v1, seg_v2, x, y, seg)
  lx = vertex_x[seg_v1[seg]]
  ly = vertex_y[seg_v1[seg]]
  ldx = core_w32_sub(vertex_x[seg_v2[seg]], lx)
  ldy = core_w32_sub(vertex_y[seg_v2[seg]], ly)
  if ldx == 0
    return x <= lx ? (ldy > 0 ? 1 : 0) : (ldy < 0 ? 1 : 0)
  end
  if ldy == 0
    return y <= ly ? (ldx < 0 ? 1 : 0) : (ldx > 0 ? 1 : 0)
  end
  dx = core_w32_sub(x, lx)
  dy = core_w32_sub(y, ly)
  neg = 0
  neg += 1 if ldy < 0
  neg += 1 if ldx < 0
  neg += 1 if dx < 0
  neg += 1 if dy < 0
  if neg % 2 == 1
    # the original compares two signs as booleans; the checker proves integer
    # comparisons, so each sign is a 0 or a 1 first
    sy = ldy < 0 ? 1 : 0
    sx = dx < 0 ? 1 : 0
    return sy != sx ? 1 : 0
  end
  left = core_fixed_mul((ldy >> 16), dx)
  right = core_fixed_mul(dy, (ldx >> 16))
  right < left ? 0 : 1
end

# `R_FindPlane`: the visplane with this height, picture and light, or a new one.
# A full table is CAPACITY, where the original raises.
def dc_find_plane(state, pl_height, pl_picnum, pl_lightlevel, pl_minx, pl_maxx, pl_top,
                  skyflatnum, sw, plw, plempty, i_lastvisplane, height, picnum, lightlevel)
  if picnum == skyflatnum[0]
    height = 0
    lightlevel = 0
  end
  i = 0
  n = state[i_lastvisplane]
  while i < n
    return i if height == pl_height[i] && picnum == pl_picnum[i] && lightlevel == pl_lightlevel[i]
    i += 1
  end
  if n == RL_MAXVISPLANES
    core_fail(:capacity)
  end
  state[i_lastvisplane] = n + 1
  pl_height[n] = height
  pl_picnum[n] = picnum
  pl_lightlevel[n] = lightlevel
  pl_minx[n] = sw[0]
  pl_maxx[n] = -1
  dc_fp_clear_plane_top(pl_top, plw, plempty, n)
  n
end

# The top clip row of visplane `i`, emptied. find_plane's copy.
def dc_fp_clear_plane_top(pl_top, plw, plempty, i)
  w = plw[0]
  b = i * w
  x = 0
  while x < w
    pl_top[b + x] = plempty[0]
    x += 1
  end
  0
end

# `R_CheckPlane`: plane `pl` widened to start..stop when no column there is
# drawn yet, otherwise a new plane with its height, picture and light.
def dc_check_plane(state, pl_height, pl_picnum, pl_lightlevel, pl_minx, pl_maxx, pl_top,
                   plw, plempty, i_lastvisplane, pl, start, stop)
  if start < pl_minx[pl]
    intrl = pl_minx[pl]
    unionl = start
  else
    unionl = pl_minx[pl]
    intrl = start
  end
  if stop > pl_maxx[pl]
    intrh = pl_maxx[pl]
    unionh = stop
  else
    unionh = pl_maxx[pl]
    intrh = stop
  end
  b = pl * plw[0] + 1
  x = intrl
  while x <= intrh && pl_top[b + x] == plempty[0]
    x += 1
  end
  if x > intrh
    pl_minx[pl] = unionl
    pl_maxx[pl] = unionh
    return pl
  end
  n = state[i_lastvisplane]
  if n == RL_MAXVISPLANES
    core_fail(:capacity)
  end
  state[i_lastvisplane] = n + 1
  pl_height[n] = pl_height[pl]
  pl_picnum[n] = pl_picnum[pl]
  pl_lightlevel[n] = pl_lightlevel[pl]
  pl_minx[n] = start
  pl_maxx[n] = stop
  dc_cp_clear_plane_top(pl_top, plw, plempty, n)
  n
end

# The top clip row of visplane `i`, emptied. check_plane's copy.
def dc_cp_clear_plane_top(pl_top, plw, plempty, i)
  w = plw[0]
  b = i * w
  x = 0
  while x < w
    pl_top[b + x] = plempty[0]
    x += 1
  end
  0
end

# `R_ClearClipSegs`: the solid-seg list as the two sentinels past the screen.
def dc_clear_clip_segs(state, ss_first, ss_last, viewwidth, i_newend)
  ss_first[0] = -0x7fffffff
  ss_last[0] = -1
  ss_first[1] = viewwidth[0]
  ss_last[1] = 0x7fffffff
  state[i_newend] = 2
  0
end

# The solid-seg list with the entries after `start` up to `nx` removed.
def dc_crunch(state, ss_first, ss_last, i_newend, start, nx)
  return 0 if nx == start
  s = start
  n = nx
  while n != state[i_newend]
    n += 1
    s += 1
    ss_first[s] = ss_first[n]
    ss_last[s] = ss_last[n]
  end
  state[i_newend] = s + 1
  0
end

