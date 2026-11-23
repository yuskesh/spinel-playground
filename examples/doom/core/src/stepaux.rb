# examples/doom/core/src/stepaux.rb — what the action knot needs besides itself.
#
# GPL-derived, from `examples/doom/lib/doom/enemy.rb`, `mapmove.rb`,
# `specials.rb` and `pspr.rb` (`Doom::Game`), which reproduce doomgeneric's
# `p_enemy.c`, `p_map.c`, `p_spec.c` and `p_pspr.c`. See ../NOTICE.md and
# ../sources.tsv.
#
# stepcore.rb's convention. Written in the port-first pass: nothing here is
# compared with the original yet.
#
# The knot itself is examples/doom/core/knot/, lowered into stepknot.rb by
# tools/doom/knot-cps.rb. It reads the constants below, and calls the leaves
# below as it calls any step definition. The original's small tables (OPPOSITE,
# DIAGS, XSPEED, YSPEED) are range trees here, and WALK_SPECIALS is a bit set,
# because the kernel admits no data table.
#
# `kn_caps` is a buffer of the capacities the knot hands to step definitions
# that take one as a scalar, since a knot frame carries no buffer sizes:
# 0 sight_stack, 1 sound_stack, 2 the switch list's pair count.

G_TMX = 80
G_TMY = 81
G_TMFLAGS = 82
G_FLOATOK = 83
G_BOMBSPOT = 84
G_BOMBSOURCE = 85
G_BOMBDAMAGE = 86
G_LA_DAMAGE = 87
G_BULLETSLOPE = 88
G_TRAVERSER = 89
G_USETHING = 90
G_PL_REFIRE = 91
G_PL_ATTACKDOWN = 92
G_PL_EXTRALIGHT = 93
G_CMD_BUTTONS = 94
G_PL_KILLCOUNT = 95
G_PL_ATTACKER = 96
G_PL_DAMAGECOUNT = 97

KN_CAP_SIGHT = 0
KN_CAP_SOUND = 1
KN_CAP_SWITCH = 2

KN_FRACUNIT = 65536
KN_MISSILERANGE = 134217728
KN_MELEERANGE = 4194304
KN_ANG90 = 1073741824
KN_ANG180 = -2147483648 # 2147483648, as its signed i32 pattern (decision 0022)
KN_ANGLETOFINESHIFT = 19
KN_FINEANGLES = 8192
KN_FINEMASK = 8191
KN_MAPBLOCKSHIFT = 23
KN_MAPBLOCKSIZE = 8388608
KN_MAPBTOFRAC = 7
KN_MAXRADIUS = 2097152
KN_FLOATSPEED = 262144
KN_BASETHRESHOLD = 100
KN_ONFLOORZ = -2147483648
KN_ML_TWOSIDED = 4

KN_MT_PLAYER = 0
KN_MT_VILE = 3
KN_MT_BRUISER = 15
KN_MT_BRUISERSHOT = 16
KN_MT_KNIGHT = 17
KN_MT_SKULL = 18
KN_MT_SPIDER = 19
KN_MT_CYBORG = 21
KN_MT_TROOPSHOT = 31
KN_MT_HEADSHOT = 32
KN_MT_ROCKET = 33
KN_MT_PLASMA = 34
KN_MT_BFG = 35
KN_MT_PUFF = 37
KN_MT_BLOOD = 38
KN_MT_TFOG = 39
KN_MT_TELEPORTMAN = 41

KN_S_NULL = 0
KN_S_CHAIN1 = 52
KN_S_PLAY = 149
KN_S_PLAY_ATK1 = 154
KN_S_PLAY_ATK2 = 155
KN_PS_WEAPON = 0
KN_PS_FLASH = 1
KN_PST_DEAD = 1
KN_WP_FIST = 0
KN_WP_PISTOL = 1
KN_WP_SHOTGUN = 2
KN_WP_CHAINGUN = 3
KN_WP_MISSILE = 4
KN_WP_BFG = 6
KN_WP_CHAINSAW = 7
KN_WP_NOCHANGE = 10
KN_PW_INVULNERABILITY = 0
KN_PW_STRENGTH = 1
KN_BT_ATTACK = 1
KN_LOWERSPEED = 393216
KN_RAISESPEED = 393216
KN_WEAPONTOP = 2097152
KN_WEAPONBOTTOM = 8388608
KN_SFX_POSIT1 = 36
KN_SFX_BGSIT1 = 39
KN_TH_MOBJ = 1
KN_VLD_NORMAL = 0
KN_VLD_OPEN = 3
KN_PT_DOWNWAITUPSTAY = 1
KN_PT_RAISETONEARESTANDCHANGE = 3
KN_FT_TURBOLOWER = 2
KN_FT_RAISEFLOOR = 3

KN_DI_EAST = 0
KN_DI_NORTH = 2
KN_DI_WEST = 4
KN_DI_SOUTH = 6
KN_DI_SOUTHEAST = 7
KN_DI_NODIR = 8

KN_MF_SPECIAL = 1
KN_MF_SOLID = 2
KN_MF_SHOOTABLE = 4
KN_MF_AMBUSH = 32
KN_MF_JUSTHIT = 64
KN_MF_JUSTATTACKED = 128
KN_MF_NOGRAVITY = 512
KN_MF_DROPOFF = 1024
KN_MF_PICKUP = 2048
KN_MF_NOCLIP = 4096
KN_MF_FLOAT = 16384
KN_MF_TELEPORT = 32768
KN_MF_MISSILE = 65536
KN_MF_DROPPED = 131072
KN_MF_SHADOW = 262144
KN_MF_NOBLOOD = 524288
KN_MF_CORPSE = 1048576
KN_MF_INFLOAT = 2097152
KN_MF_COUNTKILL = 4194304
KN_MF_SKULLFLY = 16777216

KN_ACT_BABYMETAL = 0
KN_ACT_BOSSDEATH = 3
KN_ACT_BRUISATTACK = 10
KN_ACT_CHASE = 12
KN_ACT_CHECKRELOAD = 13
KN_ACT_CPOSATTACK = 15
KN_ACT_CPOSREFIRE = 16
KN_ACT_EXPLODE = 18
KN_ACT_FACETARGET = 19
KN_ACT_FALL = 20
KN_ACT_FIRECGUN = 27
KN_ACT_FIRECRACKLE = 28
KN_ACT_FIREMISSILE = 29
KN_ACT_FIREPISTOL = 30
KN_ACT_FIRESHOTGUN = 32
KN_ACT_GUNFLASH = 34
KN_ACT_HEADATTACK = 35
KN_ACT_HOOF = 36
KN_ACT_LIGHT0 = 38
KN_ACT_LIGHT1 = 39
KN_ACT_LIGHT2 = 40
KN_ACT_LOOK = 42
KN_ACT_LOWER = 43
KN_ACT_METAL = 44
KN_ACT_PAIN = 46
KN_ACT_PLAYERSCREAM = 49
KN_ACT_POSATTACK = 50
KN_ACT_PUNCH = 51
KN_ACT_RAISE = 52
KN_ACT_REFIRE = 53
KN_ACT_SARGATTACK = 54
KN_ACT_SAW = 55
KN_ACT_SCREAM = 56
KN_ACT_SKULLATTACK = 60
KN_ACT_SPIDREFIRE = 63
KN_ACT_SPOSATTACK = 64
KN_ACT_TROOPATTACK = 67
KN_ACT_WEAPONREADY = 72
KN_ACT_XSCREAM = 73

# WALK_SPECIALS, the specials P_CrossSpecialLine names: bit s % 32 of word s / 32,
# 32-bit words (decision 0022: no constant past i32); a word with bit 31 set is
# written as its signed pattern, and `(w >> b) & 1` reads bit 31 the same way.
KN_WALK_0 = 1112225148  # 0x424b357c
KN_WALK_1 = 259002872   # 0x0f7011f8
KN_WALK_2 = -2113792    # 0xffdfbf00
KN_WALK_3 = 1937800983  # 0x73807f17
KN_WALK_4 = 8199        # 0x00002007

# `WALK_SPECIALS.include?(sp)`, as 0 or 1
def dc_st_walk_special_known(sp)
  return 0 if sp < 0 || sp >= 160
  w = sp / 32
  b = sp % 32
  return (KN_WALK_0 >> b) & 1 if w == 0
  return (KN_WALK_1 >> b) & 1 if w == 1
  return (KN_WALK_2 >> b) & 1 if w == 2
  return (KN_WALK_3 >> b) & 1 if w == 3
  (KN_WALK_4 >> b) & 1
end

# OPPOSITE[dir]: [4, 5, 6, 7, 0, 1, 2, 3, 8]
def dc_st_opposite_dir(dir)
  return dir if dir >= 8
  if dir < 4
    dir + 4
  else
    dir - 4
  end
end

# DIAGS[k]: [3, 1, 5, 7]
def dc_st_diag_dir(k)
  if k <= 1
    if k == 0
      3
    else
      1
    end
  else
    if k == 2
      5
    else
      7
    end
  end
end

# XSPEED[dir]: [65536, 47000, 0, -47000, -65536, -47000, 0, 47000]
def dc_st_xspeed(dir)
  if dir <= 3
    if dir <= 1
      if dir == 0
        65536
      else
        47000
      end
    else
      if dir == 2
        0
      else
        -47000
      end
    end
  else
    if dir <= 5
      if dir == 4
        -65536
      else
        -47000
      end
    else
      if dir == 6
        0
      else
        47000
      end
    end
  end
end

# YSPEED[dir]: [0, 47000, 65536, 47000, 0, -47000, -65536, -47000]
def dc_st_yspeed(dir)
  if dir <= 3
    if dir <= 1
      if dir == 0
        0
      else
        47000
      end
    else
      if dir == 2
        65536
      else
        47000
      end
    end
  else
    if dir <= 5
      if dir == 4
        0
      else
        -47000
      end
    else
      if dir == 6
        -65536
      else
        -47000
      end
    end
  end
end

# `Game#ptr_use_traverse`: the use line's traverser, which re-enters nothing
def dc_st_ptr_use_traverse(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, line_special,
                           line_side0, line_side1, side_sector, side_toptexture, side_midtexture, side_bottomtexture,
                           switchlist, button_line, button_where, button_texture, button_timer, mobj_player,
                           pl_cards, th_func, th_data, th_next, th_prev, dr_direction, dr_th, dr_sector, dr_type,
                           dr_topwait, dr_speed, dr_topheight, fl_th, fl_type, fl_crush, fl_sector, fl_direction,
                           fl_speed, fl_dest, pl_th, pl_type, pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low,
                           pl_wait, pl_status, activeplats, sector_floorpic, sector_special, sector_linecount,
                           sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight, line_flags,
                           line_frontsector, line_backsector, line_dx, line_dy, line_v1, vertex_x, vertex_y,
                           mobj_x, mobj_y, ic_thing, switchlist_n, idx)
  li = ic_thing[idx]
  if line_special[li] == 0
    dc_st_line_opening(state, gx, line_side1, line_frontsector, line_backsector, sector_ceilingheight,
                       sector_floorheight, li)
    return 0 if state[gx[G_OPENRANGE]] <= 0
    return 1
  end
  ut = state[gx[G_USETHING]]
  side = dc_st_point_on_line_side(line_dx, line_dy, line_v1, vertex_x, vertex_y, mobj_x[ut], mobj_y[ut], li) == 1 ? 1 : 0
  dc_st_use_special_line(state, gx, num_sectors, sector_tagno, line_tagno, sector_specialdata, line_special,
                         line_side0, line_side1, side_sector, side_toptexture, side_midtexture, side_bottomtexture,
                         switchlist, button_line, button_where, button_texture, button_timer, mobj_player,
                         pl_cards, th_func, th_data, th_next, th_prev, dr_direction, dr_th, dr_sector, dr_type,
                         dr_topwait, dr_speed, dr_topheight, fl_th, fl_type, fl_crush, fl_sector, fl_direction,
                         fl_speed, fl_dest, pl_th, pl_type, pl_sector, pl_crush, pl_tag, pl_speed, pl_high, pl_low,
                         pl_wait, pl_status, activeplats, sector_floorpic, sector_special, sector_linecount,
                         sector_lineofs, sector_lines, sector_floorheight, sector_ceilingheight, line_flags,
                         line_frontsector, line_backsector, switchlist_n, ut, li, side)
  0
end
