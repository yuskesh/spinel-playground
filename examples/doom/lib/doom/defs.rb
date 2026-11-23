# doom/lib/doom/defs.rb
#
# Constants the tic simulation shares. **They live directly under the `Doom` module.**
#
# The reason is Ruby's constant lookup: the constants visible from a method body of a mixin
# that `Doom::Game` includes (`Doom::MapMove` and others) are **the mixin's own lexical
# scope and ancestors**, not the class that includes it. Written inside `Doom::Game`,
# `MAXSPECHIT` is not visible from `Doom::MapMove#init_map_state` and raises `NameError`
# (this actually happened). Directly under `Doom`, `Doom` is in the lexical scope
# of `module Doom; module MapMove`,
# so both see them plainly.
#
# The values come from the reference implementation's headers (the enums of `doomdef.h` /
# `p_local.h` / `d_event.h` / `doomdata.h` / `info.h`). The enum numbers were **asked of
# the C compiler, not copied by hand** (`geninfo/enums.c`).

module Doom
  M32 = 0xffffffff
  SGN = 0x80000000
  M16 = 0xffff

  FRACUNIT = 0x10000
  FRACBITS = 16

  ANG45 = 0x20000000
  ANG90 = 0x40000000
  ANG180 = 0x80000000
  ANG270 = 0xc0000000
  ANGLETOFINESHIFT = 19
  FINEMASK = 8191
  FINEANGLES = 8192

  TICRATE = 35
  VIEWHEIGHT = 41 * FRACUNIT
  MAXHEALTH = 100
  GRAVITY = FRACUNIT
  MAXMOVE = 30 * FRACUNIT
  STOPSPEED = 0x1000
  FRICTION = 0xe800
  MAXBOB = 0x100000
  FLOATSPEED = 4 * FRACUNIT
  USERANGE = 64 * FRACUNIT
  MELEERANGE = 64 * FRACUNIT
  MISSILERANGE = 32 * 64 * FRACUNIT
  MAXRADIUS = 32 * FRACUNIT
  PLAYERRADIUS = 16 * FRACUNIT
  BASETHRESHOLD = 100

  MAPBLOCKSHIFT = 23
  MAPBTOFRAC = 7
  MAPBLOCKSIZE = 128 * FRACUNIT

  ONFLOORZ = -0x80000000
  ONCEILINGZ = 0x7fffffff

  # d_event.h
  BT_ATTACK = 1
  BT_USE = 2
  BT_SPECIAL = 128
  BT_SPECIALMASK = 3
  BT_CHANGE = 4
  BT_WEAPONMASK = 8 + 16 + 32
  BT_WEAPONSHIFT = 3

  # doomdata.h's linedef flags
  ML_BLOCKING = 1
  ML_BLOCKMONSTERS = 2
  ML_TWOSIDED = 4
  ML_SOUNDBLOCK = 64

  # info.h's state numbers (the reference implementation's enum values, asked of the C compiler)
  S_NULL = 0
  S_PLAY = 149
  S_PLAY_RUN1 = 150
  S_PLAY_ATK1 = 154
  S_PLAY_PAIN = 156
  S_PLAY_DIE1 = 158
  S_PLAY_XDIE1 = 165
  S_GIBS = 895

  MT_PLAYER = 0
  MT_PUFF = 37
  MT_BLOOD = 38
  MT_SKULL = 18
  MT_TROOP = 11
  MT_KNIGHT = 17
  MT_BRUISER = 15
  MT_VILE = 3
  MT_UNDEAD = 5
  MT_CYBORG = 21
  MT_SPIDER = 19
  MT_BRUISERSHOT = 16
  MT_TROOPSHOT = 31
  MT_HEADSHOT = 32
  MT_ROCKET = 33
  MT_PLASMA = 34
  MT_BFG = 35

  WP_FIST = 0
  WP_PISTOL = 1
  WP_SHOTGUN = 2
  WP_CHAINGUN = 3
  WP_MISSILE = 4
  WP_PLASMA = 5
  WP_BFG = 6
  WP_CHAINSAW = 7
  WP_NOCHANGE = 10
  NUMWEAPONS = 9
  NUMAMMO = 4
  NUMPOWERS = 6
  NUMCARDS = 6

  PW_INVULNERABILITY = 0
  PW_STRENGTH = 1
  PW_INVISIBILITY = 2
  PW_IRONFEET = 3
  PW_ALLMAP = 4
  PW_INFRARED = 5

  PST_LIVE = 0
  PST_DEAD = 1
  PST_REBORN = 2

  # p_enemy.c's dirtype_t
  DI_EAST = 0
  DI_NORTHEAST = 1
  DI_NORTH = 2
  DI_NORTHWEST = 3
  DI_WEST = 4
  DI_SOUTHWEST = 5
  DI_SOUTH = 6
  DI_SOUTHEAST = 7
  DI_NODIR = 8

  # thinker kinds (corresponding to vanilla's function pointers; 0 = marked for deferred removal)
  TH_REMOVED = 0
  TH_MOBJ = 1
  TH_LIGHTFLASH = 2
  TH_STROBE = 3
  TH_GLOW = 4
  TH_FIREFLICKER = 5
  TH_DOOR = 6
  TH_PLAT = 7
  TH_FLOOR = 8
  TH_CEILING = 9
  TH_NULL = 10

  MAXTHINKERS = 4096
  MAXMOBJS = 4096
  MAXSPECHIT = 20
  MAXINTERCEPTS = 128 + 61
  MAXPLATS = 30
  MAXBUTTONS = 16
  MAXLINEANIMS = 64

  # ---- call-site numbers for the staged oracle (layer L5 and around it) ----------
  # They correspond 1:1 to the `site` column (file:line) of the reference side's `rand.tsv`.
  # The aim is to say at once "at which call in which tic" when they split.
  SITE_SPAWNMOBJ_LASTLOOK = 1     # p_mobj.c:532
  SITE_SPAWNMAPTHING_TICS = 2     # p_mobj.c:827
  SITE_LIGHTFLASH_MIN = 3         # p_lights.c:99
  SITE_LIGHTFLASH_MAX = 4         # p_lights.c:104
  SITE_SPAWNLIGHTFLASH = 5        # p_lights.c:135
  SITE_SPAWNSTROBE = 6            # p_lights.c:199
  SITE_LOOK_POSIT = 7             # p_enemy.c:625
  SITE_LOOK_BGSIT = 8             # p_enemy.c:630
  SITE_TRYWALK_MOVECOUNT = 9      # p_enemy.c:344
  SITE_NEWCHASEDIR_SWAP = 10      # p_enemy.c:396
  SITE_NEWCHASEDIR_SEARCH = 11    # p_enemy.c:438
  SITE_CHASE_ACTIVESOUND = 12     # p_enemy.c:757
  SITE_MISSILERANGE = 13          # p_enemy.c:245
  SITE_FIREFLICKER = 14           # p_lights.c:44
  SITE_PUFF_Z = 15                # p_mobj.c:858
  SITE_PUFF_TICS = 16             # p_mobj.c:862
  SITE_BLOOD_Z = 17               # p_mobj.c:886
  SITE_BLOOD_TICS = 18            # p_mobj.c:889
  SITE_MISSILESPAWN_TICS = 19     # p_mobj.c:909
  SITE_PAINCHANCE = 20            # p_inter.c:898
  SITE_DAMAGE_THRUST = 21         # p_inter.c:724
  SITE_GUNSHOT_DAMAGE = 22        # p_pspr.c:642
  SITE_GUNSHOT_ANGLE = 23         # p_pspr.c:646
  SITE_PUNCH_DAMAGE = 24
  SITE_PUNCH_ANGLE = 25
  SITE_SAW_DAMAGE = 26
  SITE_SAW_ANGLE = 27
  SITE_FIREPISTOL = 28
  SITE_POSATTACK_ANGLE = 29       # p_enemy.c:801
  SITE_POSATTACK_DAMAGE = 30      # p_enemy.c:802
  SITE_SPOSATTACK_ANGLE = 31      # p_enemy.c:824
  SITE_SPOSATTACK_DAMAGE = 32     # p_enemy.c:825
  SITE_CPOSATTACK_ANGLE = 33
  SITE_CPOSATTACK_DAMAGE = 34
  SITE_TROOPATTACK = 35
  SITE_SARGATTACK = 36
  SITE_HEADATTACK = 37
  SITE_BRUISATTACK = 38
  SITE_SKULLATTACK = 39
  SITE_PLAYERINSPECIAL = 40
  SITE_EXPLODE = 41
  SITE_MOVE_SPECIAL = 42
  SITE_CHECKTHING_SKULL = 43
  SITE_CHECKTHING_MISSILE = 44
  SITE_NIGHTMARE = 45
  SITE_XDEATH = 46
  SITE_MISC = 47

end
