# doom/lib/doom/game.rb
#
# The body of the tic simulation (`G_Ticker` in `g_game.c` / `P_Ticker` in `p_tick.c` /
# `p_mobj.c` / `p_user.c`).
#
# ## Structural decisions
#
# Vanilla's global variables and the thinker linked list were copied into **the ivars of
# one `Doom::Game` object**. For 3 reasons:
#
#   1. C's globals (`tmfloorz` / `numspechit` / `validcount` ...) are used to **pass side
#      effects**, not return values. Scattered into arguments in Ruby, the call order
#      easily changes and determinism breaks. As ivars they copy 1:1.
#   2. mobjs are **SoA** (like `Things`). One object per mobj would allocate on
#      every spawn, hitting a later `realtime_def` head on.
#   3. `Doom::Renderer` looks up sprites by the names `sector_head` / `thing_next` /
#      `mobj_*`. **The same names are offered, so the renderer is unmodified**.
#
# The implementation is `game.rb` (the skeleton + mobjs + the player) and 6 files split
# into mixin modules (`mapmove` / `sight` / `enemy` / `specials` / `pspr` / `inter`).
# The split follows **the reference implementation's file boundaries as they are**, an
# extension of the convention to copy function names as they are. That a mixin touching ivars directly works in Spinel was measured.
#
# ## The thinker discipline
#
# Vanilla's `thinkercap` is a circular doubly linked list, and
#
#   - `P_AddThinker` appends **at the end** -> the order added = the order run
#   - `P_RemoveThinker` **does not delete at once**. It only marks the function `-1`;
#     the real deletion happens during the next `P_RunThinkers` scan
#   - **what is added during a scan runs in that same tic** (a shot moves once in the tic it is fired)
#
# these 3 are the skeleton of determinism. Here the same shape is made with index arrays
# `@th_next` / `@th_prev` + sentinel 0. **The pointers were not replaced with Ruby
# object references**: the reference implementation's dumps are tables of slot numbers,
# so the differential is plain to write.

require_relative "errors"
require_relative "defs"
require_relative "bytes"
require_relative "info"
require_relative "tables"
require_relative "level"
require_relative "texnames"
require_relative "random"
require_relative "demo"
require_relative "mapmove"
require_relative "sight"
require_relative "enemy"
require_relative "specials"
require_relative "pspr"
require_relative "inter"

module Doom
  class Game
    include MapMove
    include Sight
    include Enemy
    include Specials
    include Pspr
    include Inter

    attr_reader :level, :rnd, :leveltime, :gametic
    # The surface the renderer reads (the same names as `Doom::Things`)
    attr_reader :mobj_x, :mobj_y, :mobj_z, :mobj_angle, :mobj_type,
                :mobj_sprite, :mobj_frame, :mobj_flags, :mobj_radius,
                :mobj_height, :mobj_sector, :mobj_subsector
    attr_reader :sector_head, :thing_next
    # For the differential oracle
    attr_reader :mobj_momx, :mobj_momy, :mobj_momz, :mobj_state, :mobj_tics,
                :mobj_health, :mobj_movedir, :mobj_movecount, :mobj_reactiontime,
                :mobj_threshold, :mobj_target, :mobj_floorz, :mobj_ceilingz,
                :mobj_lastlook, :mobj_player
    attr_reader :player_mo, :pl_viewz, :pl_viewheight, :pl_deltaviewheight,
                :pl_bob, :pl_health, :pl_armorpoints, :pl_armortype,
                :pl_playerstate, :pl_readyweapon, :pl_pendingweapon,
                :pl_attackdown, :pl_usedown, :pl_refire, :pl_killcount,
                :pl_itemcount, :pl_secretcount, :pl_extralight,
                :pl_fixedcolormap, :pl_damagecount, :pl_bonuscount,
                :pl_ammo, :pl_maxammo, :pl_powers, :pl_cards, :pl_weaponowned,
                :psp_state, :psp_sx, :psp_sy, :psp_tics,
                :pl_attacker
    attr_reader :pl_message
    attr_reader :cmd_forwardmove, :cmd_sidemove, :cmd_angleturn, :cmd_buttons
    attr_reader :totalkills, :totalitems, :totalsecret

    def initialize(wad, level, skill, rnd, textures)
      @wad = wad
      @level = level
      @skill = skill
      @rnd = rnd
      @textures = textures
      @texnames = TextureNames.new(wad)
      @exit_requested = false
      @finesine = Tables.finesine
      @tantoangle = Tables.tantoangle

      @state_sprite = Info.state_sprite
      @state_frame = Info.state_frame
      @state_tics = Info.state_tics
      @state_nextstate = Info.state_nextstate
      @state_action = Info.state_action
      @state_misc1 = Info.state_misc1
      @state_misc2 = Info.state_misc2
      @sprnames = Info.sprnames
      @info_doomednum = Info.mobj_doomednum
      @info_spawnstate = Info.mobj_spawnstate
      @info_spawnhealth = Info.mobj_spawnhealth
      @info_seestate = Info.mobj_seestate
      @info_seesound = Info.mobj_seesound
      @info_reactiontime = Info.mobj_reactiontime
      @info_painstate = Info.mobj_painstate
      @info_painchance = Info.mobj_painchance
      @info_meleestate = Info.mobj_meleestate
      @info_missilestate = Info.mobj_missilestate
      @info_deathstate = Info.mobj_deathstate
      @info_deathsound = Info.mobj_deathsound
      @info_painsound = Info.mobj_painsound
      @info_attacksound = Info.mobj_attacksound
      @info_xdeathstate = Info.mobj_xdeathstate
      @info_speed = Info.mobj_speed
      @info_radius = Info.mobj_radius
      @info_height = Info.mobj_height
      @info_mass = Info.mobj_mass
      @info_damage = Info.mobj_damage
      @info_activesound = Info.mobj_activesound
      @info_flags = Info.mobj_flags
      @weapon_ammo = Info.weapon_ammo
      @weapon_upstate = Info.weapon_upstate
      @weapon_downstate = Info.weapon_downstate
      @weapon_readystate = Info.weapon_readystate
      @weapon_atkstate = Info.weapon_atkstate
      @weapon_flashstate = Info.weapon_flashstate

      init_thinkers
      init_mobjs
      init_player
      init_map_state

      @leveltime = 0
      @gametic = 0
      @validcount = 0
      @totalkills = 0
      @totalitems = 0
      @totalsecret = 0
      @soundtarget = -1

      # `P_SetupLevel`'s order: scatter THINGS, then `P_SpawnSpecials`
      load_things
      spawn_specials
    end

    # ------------------------------------------------------------------ initialization

    def init_thinkers
      # 0 is `thinkercap` (the sentinel). A circular doubly linked list.
      @th_next = Array.new(MAXTHINKERS, 0)
      @th_prev = Array.new(MAXTHINKERS, 0)
      @th_func = Array.new(MAXTHINKERS, TH_NULL)
      @th_data = Array.new(MAXTHINKERS, -1)
      @th_next[0] = 0
      @th_prev[0] = 0
      @th_alloc = 1
      @th_free = -1        # a singly linked list of freed slots (reusing @th_prev)
    end

    def init_mobjs
      n = MAXMOBJS
      @mobj_x = Array.new(n, 0)
      @mobj_y = Array.new(n, 0)
      @mobj_z = Array.new(n, 0)
      @mobj_momx = Array.new(n, 0)
      @mobj_momy = Array.new(n, 0)
      @mobj_momz = Array.new(n, 0)
      @mobj_angle = Array.new(n, 0)
      @mobj_type = Array.new(n, 0)
      @mobj_sprite = Array.new(n, 0)
      @mobj_frame = Array.new(n, 0)
      @mobj_flags = Array.new(n, 0)
      @mobj_radius = Array.new(n, 0)
      @mobj_height = Array.new(n, 0)
      @mobj_sector = Array.new(n, 0)
      @mobj_subsector = Array.new(n, 0)
      @mobj_state = Array.new(n, 0)
      @mobj_tics = Array.new(n, 0)
      @mobj_health = Array.new(n, 0)
      @mobj_movedir = Array.new(n, 0)
      @mobj_movecount = Array.new(n, 0)
      @mobj_reactiontime = Array.new(n, 0)
      @mobj_threshold = Array.new(n, 0)
      @mobj_target = Array.new(n, -1)
      @mobj_tracer = Array.new(n, -1)
      @mobj_lastlook = Array.new(n, 0)
      @mobj_floorz = Array.new(n, 0)
      @mobj_ceilingz = Array.new(n, 0)
      @mobj_player = Array.new(n, -1)
      @mobj_th = Array.new(n, -1)
      @mobj_sp_x = Array.new(n, 0)
      @mobj_sp_y = Array.new(n, 0)
      @mobj_sp_angle = Array.new(n, 0)
      @mobj_sp_type = Array.new(n, 0)
      @mobj_sp_options = Array.new(n, 0)
      @mobj_alloc = 0
      @mobj_free = -1
      # Sector / blockmap links (inserted at the head)
      @sector_head = Array.new(@level.num_sectors, -1)
      @thing_next = Array.new(n, -1)
      @thing_prev = Array.new(n, -1)
      @blocklinks = Array.new(@level.bmapwidth * @level.bmapheight, -1)
      @mobj_bnext = Array.new(n, -1)
      @mobj_bprev = Array.new(n, -1)
      @sector_soundtarget = Array.new(@level.num_sectors, -1)
      @sector_soundtraversed = Array.new(@level.num_sectors, 0)
    end

    def init_player
      @player_mo = -1
      @pl_playerstate = PST_LIVE
      @pl_viewz = 0
      @pl_viewheight = VIEWHEIGHT
      @pl_deltaviewheight = 0
      @pl_bob = 0
      @pl_health = MAXHEALTH
      @pl_armorpoints = 0
      @pl_armortype = 0
      @pl_powers = Array.new(NUMPOWERS, 0)
      @pl_cards = Array.new(NUMCARDS, 0)
      @pl_backpack = 0
      @pl_readyweapon = WP_PISTOL
      # `G_PlayerReborn` sets `pendingweapon = wp_pistol` (not
      # `wp_nochange`). `G_InitNew` puts every player in `PST_REBORN`, so
      # **even the first level always goes through the reborn route**.
      @pl_pendingweapon = WP_PISTOL
      @pl_weaponowned = Array.new(NUMWEAPONS, 0)
      @pl_weaponowned[WP_FIST] = 1
      @pl_weaponowned[WP_PISTOL] = 1
      @pl_ammo = Array.new(NUMAMMO, 0)
      @pl_ammo[0] = 50
      @pl_maxammo = Array.new(NUMAMMO, 0)
      @pl_maxammo[0] = 200
      @pl_maxammo[1] = 50
      @pl_maxammo[2] = 300
      @pl_maxammo[3] = 50
      # `G_PlayerReborn`'s initial value for "do nothing at once".
      # Set to 0, tic 0's `attackdown` splits from the reference.
      @pl_attackdown = 1
      @pl_usedown = 1
      @pl_cheats = 0
      @pl_refire = 0
      @pl_killcount = 0
      @pl_itemcount = 0
      @pl_secretcount = 0
      @pl_damagecount = 0
      @pl_bonuscount = 0
      @pl_attacker = -1
      @pl_extralight = 0
      @pl_fixedcolormap = 0
      @pl_didsecret = 0
      # `player->message`: raised for one tic only. `HU_Ticker` picks it up and clears it.
      # Kept **as a number** (the strings are `Doom::Hud::MESSAGES`, avoiding a compiler defect).
      @pl_message = 0
      @cmd_forwardmove = 0
      @cmd_sidemove = 0
      @cmd_angleturn = 0
      @cmd_buttons = 0
      @onground = false
      init_psprites
    end

    # ------------------------------------------------------------- thinker list

    # `P_AddThinker`: **appends at the end**. The order added = the order run.
    def add_thinker(func, data)
      if @th_free >= 0
        t = @th_free
        @th_free = @th_prev[t]
      else
        raise LevelError, "thinker overflow (MAXTHINKERS=#{MAXTHINKERS})" if @th_alloc >= MAXTHINKERS
        t = @th_alloc
        @th_alloc += 1
      end
      @th_func[t] = func
      @th_data[t] = data
      p = @th_prev[0]
      @th_next[p] = t
      @th_next[t] = 0
      @th_prev[t] = p
      @th_prev[0] = t
      t
    end

    # `P_RemoveThinker`: **does not delete at once**. Only sets the function to `-1` (= TH_REMOVED).
    def remove_thinker(t)
      @th_func[t] = TH_REMOVED
    end

    # `P_RunThinkers`. Reproduces deletion during the scan and addition during the scan (run in the same tic).
    def run_thinkers
      t = @th_next[0]
      while t != 0
        nxt = @th_next[t]          # semantically equivalent to vanilla's use-after-free
        f = @th_func[t]
        if f == TH_REMOVED
          @th_next[@th_prev[t]] = @th_next[t]
          @th_prev[@th_next[t]] = @th_prev[t]
          free_thinker(t)
        elsif f == TH_MOBJ
          mobj_thinker(@th_data[t])
        elsif f == TH_LIGHTFLASH
          t_light_flash(@th_data[t])
        elsif f == TH_STROBE
          t_strobe_flash(@th_data[t])
        elsif f == TH_GLOW
          t_glow(@th_data[t])
        elsif f == TH_FIREFLICKER
          t_fire_flicker(@th_data[t])
        elsif f == TH_DOOR
          t_vertical_door(@th_data[t])
        elsif f == TH_PLAT
          t_plat_raise(@th_data[t])
        elsif f == TH_FLOOR
          t_move_floor(@th_data[t])
        elsif f == TH_CEILING
          t_move_ceiling(@th_data[t])
        end
        t = nxt
      end
    end

    # Vanilla's `Z_Free`. The mobj's slot itself was already returned by `remove_mobj`
    # (vanilla's zone allocator reclaims it later). Only the thinker slot here.
    def free_thinker(t)
      @th_func[t] = TH_NULL
      @th_data[t] = -1
      @th_prev[t] = @th_free
      @th_free = t
    end

    # A thinker's slot number = the `slot` column of the reference implementation's dumps.
    def thinker_slots
      a = []
      t = @th_next[0]
      while t != 0
        a.push(t)
        t = @th_next[t]
      end
      a
    end

    # ------------------------------------------------------------------ fixed point

    def fixed_mul(a, b)
      (((a * b >> 16) & M32) ^ SGN) - SGN
    end

    # `FixedDiv` (doomgeneric's integer version). The formula is the same as `render.rb`'s
    # `fixed_div`, and it does not call the module function (`Doom::Fixed.div`), for type-inference reasons.
    def fixed_div(a, b)
      aa = a < 0 ? -a : a
      ba = b < 0 ? -b : b
      if (aa >> 14) >= ba
        (a ^ b) < 0 ? -2147483648 : 2147483647
      else
        n = a << 16
        q = (n < 0 ? -n : n) / ba
        q = -q unless (n < 0) == (b < 0)
        ((q & M32) ^ SGN) - SGN
      end
    end

    def i32(v)
      (((v & M32) ^ SGN) - SGN)
    end

    def bam(v)
      v & M32
    end

    def abs_i(v)
      v < 0 ? -v : v
    end

    # C's `/` (rounding toward 0).
    def cdiv(a, b)
      q = a.abs / b.abs
      (a < 0) != (b < 0) ? -q : q
    end

    # `P_AproxDistance`
    def aprox_distance(dx, dy)
      dx = -dx if dx < 0
      dy = -dy if dy < 0
      return dx + dy - (dx >> 1) if dx < dy
      dx + dy - (dy >> 1)
    end

    # `R_PointToAngle2` (`r_main.c`). Holds the same formula as the renderer
    # (the renderer has only the viewpoint-relative `point_to_angle`, so this is the two-point version).
    def point_to_angle2(x1, y1, x2, y2)
      x = i32(x2 - x1)
      y = i32(y2 - y1)
      return 0 if x == 0 && y == 0
      # The argument order is `SlopeDiv(num, den)`, and **the larger is den**.
      # Check it against `render.rb`'s `point_to_angle` character by character:
      # when first written, num/den were swapped in all 8 octants, the direction the
      # player slid along walls changed, and the position split at tic 60.
      if x >= 0
        if y >= 0
          if x > y
            slope_to_angle(y, x)                       # octant 0
          else
            bam(ANG90 - 1 - slope_to_angle(x, y))      # octant 1
          end
        else
          y = -y
          if x > y
            bam(-slope_to_angle(y, x))                 # octant 8
          else
            bam(ANG270 + slope_to_angle(x, y))         # octant 7
          end
        end
      else
        x = -x
        if y >= 0
          if x > y
            bam(ANG180 - 1 - slope_to_angle(y, x))     # octant 3
          else
            bam(ANG90 + slope_to_angle(x, y))          # octant 2
          end
        else
          y = -y
          if x > y
            bam(ANG180 + slope_to_angle(y, x))         # octant 4
          else
            bam(ANG270 - 1 - slope_to_angle(x, y))     # octant 5
          end
        end
      end
    end

    # `SlopeDiv` + `tantoangle`. **Arguments and arithmetic are unsigned 32-bit**
    # (the same formula as render.rb's `slope_div`).
    def slope_to_angle(num, den)
      d = den & M32
      return @tantoangle[2048] if d < 512
      ans = (((num & M32) << 3) & M32) / (d >> 8)
      @tantoangle[ans <= 2048 ? ans : 2048]
    end

    # -------------------------------------------------------------------- mobj

    def alloc_mobj
      if @mobj_free >= 0
        m = @mobj_free
        @mobj_free = @thing_next[m]
      else
        raise LevelError, "mobj overflow (MAXMOBJS=#{MAXMOBJS})" if @mobj_alloc >= MAXMOBJS
        m = @mobj_alloc
        @mobj_alloc += 1
      end
      m
    end

    def free_mobj(m)
      @thing_next[m] = @mobj_free
      @mobj_free = m
    end

    # `P_SpawnMobj`
    def spawn_mobj(x, y, z, type)
      m = alloc_mobj
      @mobj_x[m] = x
      @mobj_y[m] = y
      @mobj_momx[m] = 0
      @mobj_momy[m] = 0
      @mobj_momz[m] = 0
      @mobj_angle[m] = 0
      @mobj_type[m] = type
      @mobj_radius[m] = @info_radius[type]
      @mobj_height[m] = @info_height[type]
      @mobj_flags[m] = @info_flags[type]
      @mobj_health[m] = @info_spawnhealth[type]
      @mobj_movedir[m] = 0
      @mobj_movecount[m] = 0
      @mobj_threshold[m] = 0
      @mobj_target[m] = -1
      @mobj_tracer[m] = -1
      @mobj_player[m] = -1
      @mobj_sp_type[m] = 0
      @mobj_sp_options[m] = 0
      # skill 4 (nightmare) drops reactiontime. This port runs only skill 2, but
      # the condition is copied as the reference implementation has it.
      @mobj_reactiontime[m] = @skill == 4 ? 0 : @info_reactiontime[type]
      @mobj_lastlook[m] = @rnd.p_random(SITE_SPAWNMOBJ_LASTLOOK) % 4
      st = @info_spawnstate[type]
      @mobj_state[m] = st
      @mobj_tics[m] = @state_tics[st]
      @mobj_sprite[m] = @state_sprite[st]
      @mobj_frame[m] = @state_frame[st]
      set_thing_position(m)
      sec = @mobj_sector[m]
      @mobj_floorz[m] = @level.sector_floorheight[sec]
      @mobj_ceilingz[m] = @level.sector_ceilingheight[sec]
      if z == ONFLOORZ
        @mobj_z[m] = @mobj_floorz[m]
      elsif z == ONCEILINGZ
        @mobj_z[m] = i32(@mobj_ceilingz[m] - @info_height[type])
      else
        @mobj_z[m] = z
      end
      @mobj_th[m] = add_thinker(TH_MOBJ, m)
      m
    end

    # `P_RemoveMobj` (the item respawn queue has no effect in single player / no respawn, so it is
    # not kept. The decision not to accept `respawnparm` is made on the `Doom::Demo` side).
    def remove_mobj(m)
      unset_thing_position(m)
      remove_thinker(@mobj_th[m])
      @th_data[@mobj_th[m]] = -1
      free_mobj(m)
      @mobj_th[m] = -1
    end

    # `P_SetThingPosition`: both sector and blockmap **insert at the head**.
    def set_thing_position(m)
      ss = @level.point_in_subsector(@mobj_x[m], @mobj_y[m])
      @mobj_subsector[m] = ss
      sec = @level.ss_sector[ss]
      @mobj_sector[m] = sec
      if (@mobj_flags[m] & Info::MF_NOSECTOR) == 0
        @thing_prev[m] = -1
        h = @sector_head[sec]
        @thing_next[m] = h
        @thing_prev[h] = m if h >= 0
        @sector_head[sec] = m
      end
      if (@mobj_flags[m] & Info::MF_NOBLOCKMAP) == 0
        bx = (@mobj_x[m] - @level.bmaporgx) >> MAPBLOCKSHIFT
        by = (@mobj_y[m] - @level.bmaporgy) >> MAPBLOCKSHIFT
        if bx >= 0 && bx < @level.bmapwidth && by >= 0 && by < @level.bmapheight
          b = by * @level.bmapwidth + bx
          @mobj_bprev[m] = -1
          h = @blocklinks[b]
          @mobj_bnext[m] = h
          @mobj_bprev[h] = m if h >= 0
          @blocklinks[b] = m
        else
          @mobj_bnext[m] = -1
          @mobj_bprev[m] = -1
        end
      end
    end

    # `P_UnsetThingPosition`
    def unset_thing_position(m)
      if (@mobj_flags[m] & Info::MF_NOSECTOR) == 0
        n = @thing_next[m]
        p = @thing_prev[m]
        @thing_prev[n] = p if n >= 0
        if p >= 0
          @thing_next[p] = n
        else
          @sector_head[@mobj_sector[m]] = n
        end
      end
      if (@mobj_flags[m] & Info::MF_NOBLOCKMAP) == 0
        n = @mobj_bnext[m]
        p = @mobj_bprev[m]
        @mobj_bprev[n] = p if n >= 0
        if p >= 0
          @mobj_bnext[p] = n
        else
          bx = (@mobj_x[m] - @level.bmaporgx) >> MAPBLOCKSHIFT
          by = (@mobj_y[m] - @level.bmaporgy) >> MAPBLOCKSHIFT
          if bx >= 0 && bx < @level.bmapwidth && by >= 0 && by < @level.bmapheight
            @blocklinks[by * @level.bmapwidth + bx] = n
          end
        end
      end
    end

    # `P_SetMobjState`. **If it returns false, the mobj is gone.**
    def set_mobj_state(m, state)
      loop do
        if state == S_NULL
          @mobj_state[m] = S_NULL
          remove_mobj(m)
          return false
        end
        @mobj_state[m] = state
        @mobj_tics[m] = @state_tics[state]
        @mobj_sprite[m] = @state_sprite[state]
        @mobj_frame[m] = @state_frame[state]
        a = @state_action[state]
        dispatch_action(a, m) if a >= 0
        state = @state_nextstate[state]
        break if @mobj_tics[m] != 0
      end
      true
    end

    def mobj_removed?(m)
      t = @mobj_th[m]
      t < 0 || @th_func[t] == TH_REMOVED
    end

    # `P_MobjThinker`
    def mobj_thinker(m)
      if @mobj_momx[m] != 0 || @mobj_momy[m] != 0 ||
         (@mobj_flags[m] & Info::MF_SKULLFLY) != 0
        xy_movement(m)
        return if mobj_removed?(m)
      end
      if @mobj_z[m] != @mobj_floorz[m] || @mobj_momz[m] != 0
        z_movement(m)
        return if mobj_removed?(m)
      end
      if @mobj_tics[m] != -1
        @mobj_tics[m] -= 1
        if @mobj_tics[m] == 0
          return unless set_mobj_state(m, @state_nextstate[@mobj_state[m]])
        end
      end
      # respawnmonsters is always false in this port (`-respawn` is not accepted).
      # The nightmare respawn branch is never reached, so it is not implemented. If reached,
      # `P_Random`'s consumption would shift, but a demo with `respawnparm != 0`
      # is refused by `Doom::Demo`.
    end

    # `P_XYMovement`
    def xy_movement(m)
      if @mobj_momx[m] == 0 && @mobj_momy[m] == 0
        if (@mobj_flags[m] & Info::MF_SKULLFLY) != 0
          @mobj_flags[m] &= ~Info::MF_SKULLFLY
          @mobj_momx[m] = 0
          @mobj_momy[m] = 0
          @mobj_momz[m] = 0
          set_mobj_state(m, @info_spawnstate[@mobj_type[m]])
        end
        return
      end
      isplayer = @mobj_player[m] >= 0
      @mobj_momx[m] = MAXMOVE if @mobj_momx[m] > MAXMOVE
      @mobj_momx[m] = -MAXMOVE if @mobj_momx[m] < -MAXMOVE
      @mobj_momy[m] = MAXMOVE if @mobj_momy[m] > MAXMOVE
      @mobj_momy[m] = -MAXMOVE if @mobj_momy[m] < -MAXMOVE
      xmove = @mobj_momx[m]
      ymove = @mobj_momy[m]
      loop do
        if xmove > MAXMOVE / 2 || ymove > MAXMOVE / 2
          # Vanilla does `ptryx = mo->x + xmove/2` (**truncation toward 0**), but
          # the update right after is `xmove >>= 1` (**a shift toward the floor**).
          # They differ by 1 for negative odd numbers. Ruby's `/` floors, so `cdiv` is used where needed.
          # It was found when y split by 1 at DEMO1's tic 1955.
          ptryx = i32(@mobj_x[m] + cdiv(xmove, 2))
          ptryy = i32(@mobj_y[m] + cdiv(ymove, 2))
          xmove >>= 1
          ymove >>= 1
        else
          ptryx = i32(@mobj_x[m] + xmove)
          ptryy = i32(@mobj_y[m] + ymove)
          xmove = 0
          ymove = 0
        end
        unless try_move(m, ptryx, ptryy)
          if isplayer
            slide_move(m)
          elsif (@mobj_flags[m] & Info::MF_MISSILE) != 0
            if @ceilingline >= 0 && @level.line_backsector[@ceilingline] >= 0 &&
               @level.sector_ceilingpic[@level.line_backsector[@ceilingline]] == @level.skyflatnum
              remove_mobj(m)
              return
            end
            explode_missile(m)
          else
            @mobj_momx[m] = 0
            @mobj_momy[m] = 0
          end
        end
        break if xmove == 0 && ymove == 0
      end

      return if (@mobj_flags[m] & (Info::MF_MISSILE | Info::MF_SKULLFLY)) != 0
      return if @mobj_z[m] > @mobj_floorz[m]
      if (@mobj_flags[m] & Info::MF_CORPSE) != 0
        if @mobj_momx[m] > FRACUNIT / 4 || @mobj_momx[m] < -FRACUNIT / 4 ||
           @mobj_momy[m] > FRACUNIT / 4 || @mobj_momy[m] < -FRACUNIT / 4
          return if @mobj_floorz[m] != @level.sector_floorheight[@mobj_sector[m]]
        end
      end
      if @mobj_momx[m] > -STOPSPEED && @mobj_momx[m] < STOPSPEED &&
         @mobj_momy[m] > -STOPSPEED && @mobj_momy[m] < STOPSPEED &&
         (!isplayer || (@cmd_forwardmove == 0 && @cmd_sidemove == 0))
        if isplayer && (@mobj_state[m] - S_PLAY_RUN1) >= 0 && (@mobj_state[m] - S_PLAY_RUN1) < 4
          set_mobj_state(m, S_PLAY)
        end
        @mobj_momx[m] = 0
        @mobj_momy[m] = 0
      else
        @mobj_momx[m] = fixed_mul(@mobj_momx[m], FRICTION)
        @mobj_momy[m] = fixed_mul(@mobj_momy[m], FRICTION)
      end
    end

    # `P_ZMovement`
    def z_movement(m)
      isplayer = @mobj_player[m] >= 0
      if isplayer && @mobj_z[m] < @mobj_floorz[m]
        @pl_viewheight = i32(@pl_viewheight - (@mobj_floorz[m] - @mobj_z[m]))
        @pl_deltaviewheight = i32(VIEWHEIGHT - @pl_viewheight) >> 3
      end
      @mobj_z[m] = i32(@mobj_z[m] + @mobj_momz[m])

      if (@mobj_flags[m] & Info::MF_FLOAT) != 0 && @mobj_target[m] >= 0
        if (@mobj_flags[m] & Info::MF_SKULLFLY) == 0 &&
           (@mobj_flags[m] & Info::MF_INFLOAT) == 0
          tg = @mobj_target[m]
          dist = aprox_distance(i32(@mobj_x[m] - @mobj_x[tg]), i32(@mobj_y[m] - @mobj_y[tg]))
          delta = i32(@mobj_z[tg] + (@mobj_height[m] >> 1) - @mobj_z[m])
          if delta < 0 && dist < -(delta * 3)
            @mobj_z[m] = i32(@mobj_z[m] - FLOATSPEED)
          elsif delta > 0 && dist < delta * 3
            @mobj_z[m] = i32(@mobj_z[m] + FLOATSPEED)
          end
        end
      end

      if @mobj_z[m] <= @mobj_floorz[m]
        # gameversion >= exe_ultimate, so correct_lost_soul_bounce is true
        if (@mobj_flags[m] & Info::MF_SKULLFLY) != 0
          @mobj_momz[m] = i32(-@mobj_momz[m])
        end
        if @mobj_momz[m] < 0
          if isplayer && @mobj_momz[m] < -GRAVITY * 8
            @pl_deltaviewheight = @mobj_momz[m] >> 3
          end
          @mobj_momz[m] = 0
        end
        @mobj_z[m] = @mobj_floorz[m]
        if (@mobj_flags[m] & Info::MF_MISSILE) != 0 &&
           (@mobj_flags[m] & Info::MF_NOCLIP) == 0
          explode_missile(m)
          return
        end
      elsif (@mobj_flags[m] & Info::MF_NOGRAVITY) == 0
        if @mobj_momz[m] == 0
          @mobj_momz[m] = -GRAVITY * 2
        else
          @mobj_momz[m] = i32(@mobj_momz[m] - GRAVITY)
        end
      end

      if i32(@mobj_z[m] + @mobj_height[m]) > @mobj_ceilingz[m]
        @mobj_momz[m] = 0 if @mobj_momz[m] > 0
        @mobj_z[m] = i32(@mobj_ceilingz[m] - @mobj_height[m])
        if (@mobj_flags[m] & Info::MF_SKULLFLY) != 0
          @mobj_momz[m] = i32(-@mobj_momz[m])
        end
        if (@mobj_flags[m] & Info::MF_MISSILE) != 0 &&
           (@mobj_flags[m] & Info::MF_NOCLIP) == 0
          explode_missile(m)
        end
      end
    end

    # `P_ExplodeMissile`
    def explode_missile(m)
      @mobj_momx[m] = 0
      @mobj_momy[m] = 0
      @mobj_momz[m] = 0
      set_mobj_state(m, @info_deathstate[@mobj_type[m]])
      @mobj_tics[m] -= @rnd.p_random(SITE_MISSILESPAWN_TICS) & 3
      @mobj_tics[m] = 1 if @mobj_tics[m] < 1
      @mobj_flags[m] &= ~Info::MF_MISSILE
    end

    # `P_SpawnPuff`
    def spawn_puff(x, y, z, attackrange)
      z = i32(z + ((@rnd.p_random(SITE_PUFF_Z) - @rnd.p_random(SITE_PUFF_Z)) << 10))
      th = spawn_mobj(x, y, z, MT_PUFF)
      @mobj_momz[th] = FRACUNIT
      @mobj_tics[th] -= @rnd.p_random(SITE_PUFF_TICS) & 3
      @mobj_tics[th] = 1 if @mobj_tics[th] < 1
      set_mobj_state(th, @info_spawnstate[MT_PUFF] + 2) if attackrange == MELEERANGE
    end

    # `P_SpawnBlood`
    def spawn_blood(x, y, z, damage)
      z = i32(z + ((@rnd.p_random(SITE_BLOOD_Z) - @rnd.p_random(SITE_BLOOD_Z)) << 10))
      th = spawn_mobj(x, y, z, MT_BLOOD)
      @mobj_momz[th] = FRACUNIT * 2
      @mobj_tics[th] -= @rnd.p_random(SITE_BLOOD_TICS) & 3
      @mobj_tics[th] = 1 if @mobj_tics[th] < 1
      if damage <= 12 && damage >= 9
        set_mobj_state(th, @info_spawnstate[MT_BLOOD] + 1)
      elsif damage < 9
        set_mobj_state(th, @info_spawnstate[MT_BLOOD] + 2)
      end
    end

    # ------------------------------------------------------------ expanding THINGS

    # `P_LoadThings` + `P_SpawnMapThing` + `P_SpawnPlayer`
    def load_things
      data = @wad.bytes(@wad.map_lump(@level.mapname, "THINGS"))
      n = data.bytesize / 10
      if @skill == 0
        bit = 1
      elsif @skill == 4
        bit = 4
      else
        bit = 1 << (@skill - 1)
      end
      i = 0
      while i < n
        o = i * 10
        spawn_map_thing(Bytes.i16(data, o), Bytes.i16(data, o + 2),
                        Bytes.i16(data, o + 4), Bytes.i16(data, o + 6),
                        Bytes.i16(data, o + 8), bit)
        i += 1
      end
    end

    def spawn_map_thing(x, y, angdeg, type, options, bit)
      return if type == 11          # deathmatch start
      return if type <= 0
      if type <= 4
        spawn_player(x, y, angdeg, type) if type == 1
        return
      end
      return if (options & 16) != 0             # MTF_NOTSINGLE
      return if (options & bit) == 0
      t = 0
      t += 1 while t < @info_doomednum.length && @info_doomednum[t] != type
      raise LevelError, "unknown thing type #{type} at (#{x}, #{y})" if t == @info_doomednum.length
      z = (@info_flags[t] & Info::MF_SPAWNCEILING) != 0 ? ONCEILINGZ : ONFLOORZ
      m = spawn_mobj(x << 16, y << 16, z, t)
      @mobj_sp_x[m] = x
      @mobj_sp_y[m] = y
      @mobj_sp_angle[m] = angdeg
      @mobj_sp_type[m] = type
      @mobj_sp_options[m] = options
      if @mobj_tics[m] > 0
        @mobj_tics[m] = 1 + @rnd.p_random(SITE_SPAWNMAPTHING_TICS) % @mobj_tics[m]
      end
      @totalkills += 1 if (@mobj_flags[m] & Info::MF_COUNTKILL) != 0
      @totalitems += 1 if (@mobj_flags[m] & Info::MF_COUNTITEM) != 0
      @mobj_angle[m] = bam(ANG45 * (angdeg / 45))
      @mobj_flags[m] |= Info::MF_AMBUSH if (options & 8) != 0
    end

    def spawn_player(x, y, angdeg, _type)
      m = spawn_mobj(x << 16, y << 16, ONFLOORZ, MT_PLAYER)
      @mobj_angle[m] = bam(ANG45 * (angdeg / 45))
      @mobj_player[m] = 0
      @mobj_health[m] = @pl_health
      @player_mo = m
      @pl_playerstate = PST_LIVE
      @pl_refire = 0
      @pl_damagecount = 0
      @pl_bonuscount = 0
      @pl_extralight = 0
      @pl_fixedcolormap = 0
      @pl_viewheight = VIEWHEIGHT
      setup_psprites
    end

    # ------------------------------------------------------------------- ticker

    # The skeleton of `G_Ticker` (GS_LEVEL only). The ticcmd comes from the demo.
    def take_message
      m = @pl_message
      @pl_message = 0
      m
    end

    def g_ticker(fwd, side, aturn, buttons)
      # Vanilla's `G_Ticker` **first** checks `playerstate == PST_REBORN` and
      # triggers `G_DoReborn` -> `gameaction = ga_loadlevel` (**reloading the whole level**).
      # This port has no level reloading.
      # It never happens in DEMO1-3, but **in interactive play "die and press use"
      # triggers it at once**: the first synthetic input script actually hit it, quietly
      # stayed "dead", and drifted 26 tics from the reference implementation.
      # "Not implemented yet" is never let through quietly.
      if @pl_playerstate == PST_REBORN
        raise LevelError,
              "G_DoReborn (ga_loadlevel) is not implemented: the player died " \
              "and pressed use at gametic #{@gametic}"
      end
      @cmd_forwardmove = fwd
      @cmd_sidemove = side
      @cmd_angleturn = aturn
      @cmd_buttons = buttons
      p_ticker
      @gametic += 1
    end

    # `P_Ticker`: **the order of these 5 steps is the skeleton of determinism**.
    def p_ticker
      player_think
      run_thinkers
      update_specials
      # P_RespawnSpecials is deathmatch only, so it does nothing
      @leveltime += 1
    end

    # ------------------------------------------------------------------ player

    # `P_PlayerThink`
    def player_think
      m = @player_mo
      if (@mobj_flags[m] & Info::MF_JUSTATTACKED) != 0
        @cmd_angleturn = 0
        @cmd_forwardmove = 0xc800 / 512
        @cmd_sidemove = 0
        @mobj_flags[m] &= ~Info::MF_JUSTATTACKED
      end
      if @pl_playerstate == PST_DEAD
        death_think
        return
      end
      if @mobj_reactiontime[m] != 0
        @mobj_reactiontime[m] -= 1
      else
        move_player
      end
      calc_height
      player_in_special_sector if @level.sector_special[@mobj_sector[m]] != 0

      @cmd_buttons = 0 if (@cmd_buttons & BT_SPECIAL) != 0
      if (@cmd_buttons & BT_CHANGE) != 0
        newweapon = (@cmd_buttons & BT_WEAPONMASK) >> BT_WEAPONSHIFT
        if newweapon == WP_FIST && @pl_weaponowned[WP_CHAINSAW] != 0 &&
           !(@pl_readyweapon == WP_CHAINSAW && @pl_powers[PW_STRENGTH] != 0)
          newweapon = WP_CHAINSAW
        end
        if @pl_weaponowned[newweapon] != 0 && newweapon != @pl_readyweapon
          # shareware cannot switch to plasma / bfg
          if newweapon != WP_PLASMA && newweapon != WP_BFG
            @pl_pendingweapon = newweapon
          end
        end
      end

      if (@cmd_buttons & BT_USE) != 0
        if @pl_usedown == 0
          use_lines
          @pl_usedown = 1
        end
      else
        @pl_usedown = 0
      end

      move_psprites

      @pl_powers[PW_STRENGTH] += 1 if @pl_powers[PW_STRENGTH] != 0
      @pl_powers[PW_INVULNERABILITY] -= 1 if @pl_powers[PW_INVULNERABILITY] != 0
      if @pl_powers[PW_INVISIBILITY] != 0
        @pl_powers[PW_INVISIBILITY] -= 1
        @mobj_flags[m] &= ~Info::MF_SHADOW if @pl_powers[PW_INVISIBILITY] == 0
      end
      @pl_powers[PW_INFRARED] -= 1 if @pl_powers[PW_INFRARED] != 0
      @pl_powers[PW_IRONFEET] -= 1 if @pl_powers[PW_IRONFEET] != 0
      @pl_damagecount -= 1 if @pl_damagecount != 0
      @pl_bonuscount -= 1 if @pl_bonuscount != 0

      if @pl_powers[PW_INVULNERABILITY] != 0
        @pl_fixedcolormap =
          (@pl_powers[PW_INVULNERABILITY] > 4 * 32 ||
           (@pl_powers[PW_INVULNERABILITY] & 8) != 0) ? 32 : 0
      elsif @pl_powers[PW_INFRARED] != 0
        @pl_fixedcolormap =
          (@pl_powers[PW_INFRARED] > 4 * 32 ||
           (@pl_powers[PW_INFRARED] & 8) != 0) ? 1 : 0
      else
        @pl_fixedcolormap = 0
      end
    end

    # `P_MovePlayer`
    def move_player
      m = @player_mo
      @mobj_angle[m] = bam(@mobj_angle[m] + (@cmd_angleturn << 16))
      @onground = @mobj_z[m] <= @mobj_floorz[m]
      thrust(@mobj_angle[m], @cmd_forwardmove * 2048) if @cmd_forwardmove != 0 && @onground
      thrust(bam(@mobj_angle[m] - ANG90), @cmd_sidemove * 2048) if @cmd_sidemove != 0 && @onground
      if (@cmd_forwardmove != 0 || @cmd_sidemove != 0) && @mobj_state[m] == S_PLAY
        set_mobj_state(m, S_PLAY_RUN1)
      end
    end

    # `P_Thrust`
    def thrust(angle, move)
      a = angle >> ANGLETOFINESHIFT
      m = @player_mo
      @mobj_momx[m] = i32(@mobj_momx[m] + fixed_mul(move, @finesine[a + 2048]))
      @mobj_momy[m] = i32(@mobj_momy[m] + fixed_mul(move, @finesine[a]))
    end

    # `P_CalcHeight`
    def calc_height
      m = @player_mo
      @pl_bob = i32(fixed_mul(@mobj_momx[m], @mobj_momx[m]) +
                    fixed_mul(@mobj_momy[m], @mobj_momy[m]))
      @pl_bob >>= 2
      @pl_bob = MAXBOB if @pl_bob > MAXBOB

      unless @onground
        @pl_viewz = i32(@mobj_z[m] + @pl_viewheight)
        return
      end
      angle = (FINEANGLES / 20 * @leveltime) & FINEMASK
      bob = fixed_mul(@pl_bob / 2, @finesine[angle])
      if @pl_playerstate == PST_LIVE
        @pl_viewheight = i32(@pl_viewheight + @pl_deltaviewheight)
        if @pl_viewheight > VIEWHEIGHT
          @pl_viewheight = VIEWHEIGHT
          @pl_deltaviewheight = 0
        end
        if @pl_viewheight < VIEWHEIGHT / 2
          @pl_viewheight = VIEWHEIGHT / 2
          @pl_deltaviewheight = 1 if @pl_deltaviewheight <= 0
        end
        if @pl_deltaviewheight != 0
          @pl_deltaviewheight = i32(@pl_deltaviewheight + FRACUNIT / 4)
          @pl_deltaviewheight = 1 if @pl_deltaviewheight == 0
        end
      end
      @pl_viewz = i32(@mobj_z[m] + @pl_viewheight + bob)
      top = i32(@mobj_ceilingz[m] - 4 * FRACUNIT)
      @pl_viewz = top if @pl_viewz > top
    end

    # `P_DeathThink`
    def death_think
      m = @player_mo
      move_psprites
      @pl_viewheight -= FRACUNIT if @pl_viewheight > 6 * FRACUNIT
      @pl_viewheight = 6 * FRACUNIT if @pl_viewheight < 6 * FRACUNIT
      @pl_deltaviewheight = 0
      @onground = @mobj_z[m] <= @mobj_floorz[m]
      calc_height
      if @pl_attacker >= 0 && @pl_attacker != m
        angle = point_to_angle2(@mobj_x[m], @mobj_y[m],
                                @mobj_x[@pl_attacker], @mobj_y[@pl_attacker])
        delta = bam(angle - @mobj_angle[m])
        ang5 = ANG90 / 18
        if delta < ang5 || delta > bam(-ang5)
          @mobj_angle[m] = angle
          @pl_damagecount -= 1 if @pl_damagecount != 0
        elsif delta < ANG180
          @mobj_angle[m] = bam(@mobj_angle[m] + ang5)
        else
          @mobj_angle[m] = bam(@mobj_angle[m] - ang5)
        end
      elsif @pl_damagecount != 0
        @pl_damagecount -= 1
      end
      @pl_playerstate = PST_REBORN if (@cmd_buttons & BT_USE) != 0
    end

    # The viewpoint (`R_SetupFrame`). The 4 values passed to the renderer.
    def viewx
      @mobj_x[@player_mo]
    end

    def viewy
      @mobj_y[@player_mo]
    end

    def viewz
      @pl_viewz
    end

    def viewangle
      @mobj_angle[@player_mo]
    end

    def extralight
      @pl_extralight
    end

    def num_mobjs
      @mobj_alloc
    end

    def th_func(t)
      @th_func[t]
    end

    def th_data(t)
      @th_data[t]
    end
  end
end
