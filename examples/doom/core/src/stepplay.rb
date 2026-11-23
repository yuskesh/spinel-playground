# examples/doom/core/src/stepplay.rb — constants and the thinker sweep for the step entry above the knot.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `mapmove.rb`,
# `specials.rb`, `enemy.rb` and `pspr.rb` (`Doom::Game`), which reproduce
# doomgeneric's `g_game.c`, `p_tick.c`, `p_user.c`, `p_mobj.c`, `p_map.c`,
# `p_floor.c`, `p_plats.c`, `p_doors.c`, `p_spec.c` and `p_pspr.c`. See
# ../NOTICE.md and ../sources.tsv.
#
# stepcore.rb's convention. Written in the port-first pass: nothing here is
# compared with the original yet.
#
# The definitions themselves are direct-style in ../knot/play.rb and lowered
# into stepknot.rb with the action knot, so that the knot's buffers meet at one
# dispatcher. What stays here is what they share with the hand-written step
# files -- the state slots and constants -- and the free-list sweep, which
# re-enters nothing.

G_NOFIT = 98
G_CRUSHCHANGE = 99
G_CMD_FORWARDMOVE = 100
G_CMD_SIDEMOVE = 101
G_CMD_ANGLETURN = 102
G_GAMETIC = 103
G_PL_USEDOWN = 104
G_PL_FIXEDCOLORMAP = 105
G_PL_SECRETCOUNT = 106
# the menu generator's cells, which the step entry draws on (dc_st_m_random)
G_RNDINDEX = 107
G_MCOUNT = 108

SP_FRACUNIT = 65536
SP_ANG90 = 1073741824
SP_ANG180 = -2147483648 # 2147483648, as its signed i32 pattern (decision 0022)
SP_ANGLETOFINESHIFT = 19
SP_VIEWHEIGHT = 2686976
SP_FLOATSPEED = 262144
SP_MAXMOVE = 1966080
SP_STOPSPEED = 4096
SP_FRICTION = 59392
SP_GRAVITY = 65536
SP_USERANGE = 4194304
SP_S_PLAY = 149
SP_S_PLAY_RUN1 = 150
SP_S_GIBS = 895
SP_MT_BLOOD = 38
SP_BT_USE = 2
SP_BT_CHANGE = 4
SP_BT_WEAPONMASK = 56
SP_BT_WEAPONSHIFT = 3
SP_BT_SPECIAL = 128
SP_PST_DEAD = 1
SP_PST_REBORN = 2
SP_NUMPSPRITES = 2
SP_PS_WEAPON = 0
SP_PS_FLASH = 1
SP_TH_REMOVED = 0
SP_TH_MOBJ = 1
SP_TH_LIGHTFLASH = 2
SP_TH_STROBE = 3
SP_TH_GLOW = 4
SP_TH_FIREFLICKER = 5
SP_TH_DOOR = 6
SP_TH_PLAT = 7
SP_TH_FLOOR = 8
SP_TH_CEILING = 9
SP_TH_NULL = 10
SP_PLAT_UP = 0
SP_PLAT_DOWN = 1
SP_PLAT_WAITING = 2
SP_PT_DOWNWAITUPSTAY = 1
SP_PT_RAISEANDCHANGE = 2
SP_PT_RAISETONEARESTANDCHANGE = 3
SP_VLD_NORMAL = 0
SP_VLD_CLOSE30 = 1
SP_VLD_CLOSE = 2
SP_VLD_OPEN = 3
SP_VLD_RAISEIN5MINS = 4
SP_TICRATE = 35
SP_PW_INVULNERABILITY = 0
SP_PW_STRENGTH = 1
SP_PW_INVISIBILITY = 2
SP_PW_IRONFEET = 3
SP_PW_INFRARED = 5
SP_WP_FIST = 0
SP_WP_PLASMA = 5
SP_WP_BFG = 6
SP_WP_CHAINSAW = 7
SP_MF_SOLID = 2
SP_MF_SHOOTABLE = 4
SP_MF_JUSTATTACKED = 128
SP_MF_NOCLIP = 4096
SP_MF_FLOAT = 16384
SP_MF_MISSILE = 65536
SP_MF_DROPPED = 131072
SP_MF_SHADOW = 262144
SP_MF_CORPSE = 1048576
SP_MF_INFLOAT = 2097152
SP_MF_SKULLFLY = 16777216
SP_MF_NOGRAVITY = 512

# `Game#free_thinker`: thinkers.rb's dc_free_slot, over the free-list cell
def dc_st_free_thinker(th_func, th_data, th_prev, state, gx, t)
  th_func[t] = SP_TH_NULL
  th_data[t] = -1
  th_prev[t] = state[gx[G_TH_FREE]]
  state[gx[G_TH_FREE]] = t
  t
end

# `Game#take_message`: the pending message, and the cell cleared
def dc_st_take_message(state, gx)
  m = state[gx[G_PL_MESSAGE]]
  state[gx[G_PL_MESSAGE]] = 0
  m
end
