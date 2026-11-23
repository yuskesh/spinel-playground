# doom/lib/doom/enemy.rb
#
# Enemy AI and action functions (`p_enemy.c`), and lines of fire (`P_AimLineAttack` /
# `P_LineAttack` / `P_UseLines` in `p_map.c`). A mixin included in `Doom::Game`.
#
# ## Dispatching action functions
#
# Vanilla keeps a function pointer in `states[].action`. This port has, as
# `Info.state_action`, **a column `tools/gen_info.py` made from `info.o` by turning the
# function pointers back into names and then numbers**, and turns it into a `case` here.
#
# **An action that is not implemented fails loudly.** The lesson of the drawing stages was to
# keep "implemented" apart from "ran", so routes that have not run are made visible by exceptions.
#
# ## Where `P_Random` is consumed
#
# The AI is where demos are won or lost. Measured on DEMO1's first 400 tics,
# 8 sites in `p_enemy.c` take 80% of the total. The `SITE_*` constants correspond 1:1 to
# `file:line` in the reference side's `rand.tsv`, so the moment they split
# **which call in which tic** can be said.

require_relative "defs"
require_relative "info"

module Doom
  module Enemy
    SFX_NONE = 0
    SFX_PISTOL = 1
    SFX_POSIT1 = 36
    SFX_BGSIT1 = 39
    SFX_PODTH1 = 59
    SFX_BGDTH1 = 62

    XSPEED = [0x10000, 47000, 0, -47000, -0x10000, -47000, 0, 47000].freeze
    YSPEED = [0, 47000, 0x10000, 47000, 0, -47000, -0x10000, -47000].freeze
    OPPOSITE = [4, 5, 6, 7, 0, 1, 2, 3, 8].freeze
    DIAGS = [3, 1, 5, 7].freeze     # NORTHWEST, NORTHEAST, SOUTHWEST, SOUTHEAST

    # `states[].action` number -> implementation. **What is not implemented raises.**
    def dispatch_action(a, m)
      case a
      when Info::ACT_LOOK then a_look(m)
      when Info::ACT_CHASE then a_chase(m)
      when Info::ACT_FACETARGET then a_face_target(m)
      when Info::ACT_POSATTACK then a_pos_attack(m)
      when Info::ACT_SPOSATTACK then a_spos_attack(m)
      when Info::ACT_CPOSATTACK then a_cpos_attack(m)
      when Info::ACT_CPOSREFIRE then a_cpos_refire(m)
      when Info::ACT_SPIDREFIRE then a_spid_refire(m)
      when Info::ACT_TROOPATTACK then a_troop_attack(m)
      when Info::ACT_SARGATTACK then a_sarg_attack(m)
      when Info::ACT_HEADATTACK then a_head_attack(m)
      when Info::ACT_BRUISATTACK then a_bruis_attack(m)
      when Info::ACT_SKULLATTACK then a_skull_attack(m)
      when Info::ACT_SCREAM then a_scream(m)
      when Info::ACT_XSCREAM then nil                   # sound only
      when Info::ACT_PAIN then nil                      # sound only
      when Info::ACT_PLAYERSCREAM then nil              # sound only
      when Info::ACT_FALL then a_fall(m)
      when Info::ACT_EXPLODE then a_explode(m)
      when Info::ACT_BOSSDEATH then a_boss_death(m)
      when Info::ACT_HOOF, Info::ACT_METAL, Info::ACT_BABYMETAL,
           Info::ACT_FIRECRACKLE then a_chase(m)        # sound + A_Chase
      else
        raise LevelError, "unimplemented mobj action #{a} on mobj #{m} (type #{@mobj_type[m]})"
      end
    end

    # ------------------------------------------------------------------ looking for targets

    # `P_CheckMeleeRange`
    def check_melee_range(actor)
      tg = @mobj_target[actor]
      return false if tg < 0
      dist = aprox_distance(i32(@mobj_x[tg] - @mobj_x[actor]),
                            i32(@mobj_y[tg] - @mobj_y[actor]))
      return false if dist >= i32(MELEERANGE - 20 * FRACUNIT + @info_radius[@mobj_type[tg]])
      check_sight(actor, tg)
    end

    # `P_CheckMissileRange`
    def check_missile_range(actor)
      tg = @mobj_target[actor]
      return false unless check_sight(actor, tg)
      if (@mobj_flags[actor] & Info::MF_JUSTHIT) != 0
        @mobj_flags[actor] &= ~Info::MF_JUSTHIT
        return true
      end
      return false if @mobj_reactiontime[actor] != 0
      dist = i32(aprox_distance(i32(@mobj_x[actor] - @mobj_x[tg]),
                                i32(@mobj_y[actor] - @mobj_y[tg])) - 64 * FRACUNIT)
      dist = i32(dist - 128 * FRACUNIT) if @info_meleestate[@mobj_type[actor]] == 0
      dist >>= 16
      t = @mobj_type[actor]
      return false if t == MT_VILE && dist > 14 * 64
      if t == MT_UNDEAD
        return false if dist < 196
        dist >>= 1
      end
      dist >>= 1 if t == MT_CYBORG || t == MT_SPIDER || t == MT_SKULL
      dist = 200 if dist > 200
      dist = 160 if t == MT_CYBORG && dist > 160
      return false if @rnd.p_random(SITE_MISSILERANGE) < dist
      true
    end

    # `P_LookForPlayers`. Single player, so playeringame is [true,f,f,f].
    def look_for_players(actor, allaround)
      c = 0
      stop = (@mobj_lastlook[actor] - 1) & 3
      loop do
        if @mobj_lastlook[actor] != 0
          # playeringame[1..3] are false, so `continue`
          @mobj_lastlook[actor] = (@mobj_lastlook[actor] + 1) & 3
          next
        end
        if c == 2 || @mobj_lastlook[actor] == stop
          return false
        end
        c += 1
        pm = @player_mo
        if @pl_health > 0 && check_sight(actor, pm)
          ok = true
          unless allaround
            an = bam(point_to_angle2(@mobj_x[actor], @mobj_y[actor],
                                     @mobj_x[pm], @mobj_y[pm]) - @mobj_angle[actor])
            if an > ANG90 && an < ANG270
              dist = aprox_distance(i32(@mobj_x[pm] - @mobj_x[actor]),
                                    i32(@mobj_y[pm] - @mobj_y[actor]))
              ok = false if dist > MELEERANGE
            end
          end
          if ok
            @mobj_target[actor] = pm
            return true
          end
        end
        @mobj_lastlook[actor] = (@mobj_lastlook[actor] + 1) & 3
      end
    end

    # `A_Look`
    def a_look(actor)
      @mobj_threshold[actor] = 0
      targ = @sector_soundtarget[@mobj_sector[actor]]
      seeyou = false
      if targ >= 0 && (@mobj_flags[targ] & Info::MF_SHOOTABLE) != 0
        @mobj_target[actor] = targ
        if (@mobj_flags[actor] & Info::MF_AMBUSH) != 0
          seeyou = true if check_sight(actor, targ)
        else
          seeyou = true
        end
      end
      unless seeyou
        return unless look_for_players(actor, false)
      end
      ss = @info_seesound[@mobj_type[actor]]
      if ss != 0
        if ss == SFX_POSIT1 || ss == SFX_POSIT1 + 1 || ss == SFX_POSIT1 + 2
          @rnd.p_random(SITE_LOOK_POSIT)
        elsif ss == SFX_BGSIT1 || ss == SFX_BGSIT1 + 1
          @rnd.p_random(SITE_LOOK_BGSIT)
        end
      end
      set_mobj_state(actor, @info_seestate[@mobj_type[actor]])
    end

    # `A_Chase`
    def a_chase(actor)
      @mobj_reactiontime[actor] -= 1 if @mobj_reactiontime[actor] != 0
      if @mobj_threshold[actor] != 0
        tg = @mobj_target[actor]
        if tg < 0 || @mobj_health[tg] <= 0
          @mobj_threshold[actor] = 0
        else
          @mobj_threshold[actor] -= 1
        end
      end
      if @mobj_movedir[actor] < 8
        @mobj_angle[actor] &= (7 << 29)
        delta = i32(@mobj_angle[actor] - (@mobj_movedir[actor] << 29))
        if delta > 0
          @mobj_angle[actor] = bam(@mobj_angle[actor] - ANG90 / 2)
        elsif delta < 0
          @mobj_angle[actor] = bam(@mobj_angle[actor] + ANG90 / 2)
        end
      end
      tg = @mobj_target[actor]
      if tg < 0 || (@mobj_flags[tg] & Info::MF_SHOOTABLE) == 0
        return if look_for_players(actor, true)
        set_mobj_state(actor, @info_spawnstate[@mobj_type[actor]])
        return
      end
      if (@mobj_flags[actor] & Info::MF_JUSTATTACKED) != 0
        @mobj_flags[actor] &= ~Info::MF_JUSTATTACKED
        new_chase_dir(actor) if @skill != 4
        return
      end
      if @info_meleestate[@mobj_type[actor]] != 0 && check_melee_range(actor)
        set_mobj_state(actor, @info_meleestate[@mobj_type[actor]])
        return
      end
      nomissile = false
      if @info_missilestate[@mobj_type[actor]] != 0
        if @skill < 4 && @mobj_movecount[actor] != 0
          nomissile = true
        elsif !check_missile_range(actor)
          nomissile = true
        end
        unless nomissile
          set_mobj_state(actor, @info_missilestate[@mobj_type[actor]])
          @mobj_flags[actor] |= Info::MF_JUSTATTACKED
          return
        end
      end
      # the netgame branch is not taken in single player
      @mobj_movecount[actor] -= 1
      if @mobj_movecount[actor] < 0 || !p_move(actor)
        new_chase_dir(actor)
      end
      if @info_activesound[@mobj_type[actor]] != 0
        @rnd.p_random(SITE_CHASE_ACTIVESOUND)
      end
    end

    # `A_FaceTarget`
    def a_face_target(actor)
      tg = @mobj_target[actor]
      return if tg < 0
      @mobj_flags[actor] &= ~Info::MF_AMBUSH
      @mobj_angle[actor] = point_to_angle2(@mobj_x[actor], @mobj_y[actor],
                                           @mobj_x[tg], @mobj_y[tg])
      if (@mobj_flags[tg] & Info::MF_SHADOW) != 0
        @mobj_angle[actor] = bam(@mobj_angle[actor] +
                                 ((@rnd.p_random(SITE_MISC) - @rnd.p_random(SITE_MISC)) << 21))
      end
    end

    # `A_Fall`
    def a_fall(actor)
      @mobj_flags[actor] &= ~Info::MF_SOLID
    end

    def a_scream(actor)
      ds = @info_deathsound[@mobj_type[actor]]
      return if ds == 0
      if ds == SFX_PODTH1 || ds == SFX_PODTH1 + 1 || ds == SFX_PODTH1 + 2
        @rnd.p_random(SITE_MISC)
      elsif ds == SFX_BGDTH1 || ds == SFX_BGDTH1 + 1
        @rnd.p_random(SITE_MISC)
      end
    end

    def a_explode(actor)
      radius_attack(actor, @mobj_target[actor], 128)
    end

    def a_boss_death(_actor)
      # Only for E1M8's finale (`CheckBossEnd`). Not reached in E1M5.
      raise LevelError, "A_BossDeath reached (not implemented for this map)"
    end

    # ---------------------------------------------------------------- movement AI

    # `P_Move`
    def p_move(actor)
      return false if @mobj_movedir[actor] == DI_NODIR
      raise LevelError, "weird movedir #{@mobj_movedir[actor]}" if @mobj_movedir[actor] >= 8
      speed = @info_speed[@mobj_type[actor]]
      tryx = i32(@mobj_x[actor] + speed * XSPEED[@mobj_movedir[actor]])
      tryy = i32(@mobj_y[actor] + speed * YSPEED[@mobj_movedir[actor]])
      if try_move(actor, tryx, tryy)
        @mobj_flags[actor] &= ~Info::MF_INFLOAT
        @mobj_z[actor] = @mobj_floorz[actor] if (@mobj_flags[actor] & Info::MF_FLOAT) == 0
        return true
      end
      if (@mobj_flags[actor] & Info::MF_FLOAT) != 0 && @floatok
        if @mobj_z[actor] < @tmfloorz
          @mobj_z[actor] = i32(@mobj_z[actor] + FLOATSPEED)
        else
          @mobj_z[actor] = i32(@mobj_z[actor] - FLOATSPEED)
        end
        @mobj_flags[actor] |= Info::MF_INFLOAT
        return true
      end
      return false if @numspechit == 0
      @mobj_movedir[actor] = DI_NODIR
      good = false
      while @numspechit > 0
        @numspechit -= 1
        good = true if use_special_line(actor, @spechit[@numspechit], 0)
      end
      good
    end

    # `P_TryWalk`
    def try_walk(actor)
      return false unless p_move(actor)
      @mobj_movecount[actor] = @rnd.p_random(SITE_TRYWALK_MOVECOUNT) & 15
      true
    end

    # `P_NewChaseDir`
    def new_chase_dir(actor)
      tg = @mobj_target[actor]
      raise LevelError, "P_NewChaseDir called with no target" if tg < 0
      olddir = @mobj_movedir[actor]
      turnaround = OPPOSITE[olddir]
      deltax = i32(@mobj_x[tg] - @mobj_x[actor])
      deltay = i32(@mobj_y[tg] - @mobj_y[actor])
      if deltax > 10 * FRACUNIT
        d1 = DI_EAST
      elsif deltax < -10 * FRACUNIT
        d1 = DI_WEST
      else
        d1 = DI_NODIR
      end
      if deltay < -10 * FRACUNIT
        d2 = DI_SOUTH
      elsif deltay > 10 * FRACUNIT
        d2 = DI_NORTH
      else
        d2 = DI_NODIR
      end
      if d1 != DI_NODIR && d2 != DI_NODIR
        @mobj_movedir[actor] =
          DIAGS[((deltay < 0 ? 1 : 0) << 1) + (deltax > 0 ? 1 : 0)]
        return if @mobj_movedir[actor] != turnaround && try_walk(actor)
      end
      if @rnd.p_random(SITE_NEWCHASEDIR_SWAP) > 200 || abs_i(deltay) > abs_i(deltax)
        t = d1
        d1 = d2
        d2 = t
      end
      d1 = DI_NODIR if d1 == turnaround
      d2 = DI_NODIR if d2 == turnaround
      if d1 != DI_NODIR
        @mobj_movedir[actor] = d1
        return if try_walk(actor)
      end
      if d2 != DI_NODIR
        @mobj_movedir[actor] = d2
        return if try_walk(actor)
      end
      if olddir != DI_NODIR
        @mobj_movedir[actor] = olddir
        return if try_walk(actor)
      end
      if (@rnd.p_random(SITE_NEWCHASEDIR_SEARCH) & 1) != 0
        tdir = DI_EAST
        while tdir <= DI_SOUTHEAST
          if tdir != turnaround
            @mobj_movedir[actor] = tdir
            return if try_walk(actor)
          end
          tdir += 1
        end
      else
        tdir = DI_SOUTHEAST
        while tdir != DI_EAST - 1
          if tdir != turnaround
            @mobj_movedir[actor] = tdir
            return if try_walk(actor)
          end
          tdir -= 1
        end
      end
      if turnaround != DI_NODIR
        @mobj_movedir[actor] = turnaround
        return if try_walk(actor)
      end
      @mobj_movedir[actor] = DI_NODIR
    end

    # `P_NoiseAlert` / `P_RecursiveSound`
    def noise_alert(target, emmiter)
      @soundtarget = target
      @validcount += 1
      recursive_sound(@mobj_sector[emmiter], 0)
    end

    def recursive_sound(sec, soundblocks)
      lv = @level
      return if lv.sector_validcount[sec] == @validcount &&
                @sector_soundtraversed[sec] <= soundblocks + 1
      lv.sector_validcount[sec] = @validcount
      @sector_soundtraversed[sec] = soundblocks + 1
      @sector_soundtarget[sec] = @soundtarget
      c = lv.sector_linecount[sec]
      o = lv.sector_lineofs[sec]
      i = 0
      while i < c
        check = lv.sector_lines[o + i]
        i += 1
        next if (lv.line_flags[check] & ML_TWOSIDED) == 0
        line_opening(check)
        next if @openrange <= 0
        s0 = lv.side_sector[lv.line_side0[check]]
        other = s0 == sec ? lv.side_sector[lv.line_side1[check]] : s0
        if (lv.line_flags[check] & ML_SOUNDBLOCK) != 0
          recursive_sound(other, 1) if soundblocks == 0
        else
          recursive_sound(other, soundblocks)
        end
      end
    end

    # ------------------------------------------------------------- attacks (lines of fire)

    # `A_PosAttack`
    def a_pos_attack(actor)
      return if @mobj_target[actor] < 0
      a_face_target(actor)
      angle = @mobj_angle[actor]
      slope = aim_line_attack(actor, angle, MISSILERANGE)
      angle = bam(angle + ((@rnd.p_random(SITE_POSATTACK_ANGLE) -
                            @rnd.p_random(SITE_POSATTACK_ANGLE)) << 20))
      damage = ((@rnd.p_random(SITE_POSATTACK_DAMAGE) % 5) + 1) * 3
      line_attack(actor, angle, MISSILERANGE, slope, damage)
    end

    def a_spos_attack(actor)
      return if @mobj_target[actor] < 0
      a_face_target(actor)
      bangle = @mobj_angle[actor]
      slope = aim_line_attack(actor, bangle, MISSILERANGE)
      i = 0
      while i < 3
        angle = bam(bangle + ((@rnd.p_random(SITE_SPOSATTACK_ANGLE) -
                               @rnd.p_random(SITE_SPOSATTACK_ANGLE)) << 20))
        damage = ((@rnd.p_random(SITE_SPOSATTACK_DAMAGE) % 5) + 1) * 3
        line_attack(actor, angle, MISSILERANGE, slope, damage)
        i += 1
      end
    end

    def a_cpos_attack(actor)
      return if @mobj_target[actor] < 0
      a_face_target(actor)
      bangle = @mobj_angle[actor]
      slope = aim_line_attack(actor, bangle, MISSILERANGE)
      angle = bam(bangle + ((@rnd.p_random(SITE_CPOSATTACK_ANGLE) -
                             @rnd.p_random(SITE_CPOSATTACK_ANGLE)) << 20))
      damage = ((@rnd.p_random(SITE_CPOSATTACK_DAMAGE) % 5) + 1) * 3
      line_attack(actor, angle, MISSILERANGE, slope, damage)
    end

    def a_cpos_refire(actor)
      a_face_target(actor)
      return if @rnd.p_random(SITE_MISC) < 40
      tg = @mobj_target[actor]
      if tg < 0 || @mobj_health[tg] <= 0 || !check_sight(actor, tg)
        set_mobj_state(actor, @info_seestate[@mobj_type[actor]])
      end
    end

    def a_spid_refire(actor)
      a_face_target(actor)
      return if @rnd.p_random(SITE_MISC) < 10
      tg = @mobj_target[actor]
      if tg < 0 || @mobj_health[tg] <= 0 || !check_sight(actor, tg)
        set_mobj_state(actor, @info_seestate[@mobj_type[actor]])
      end
    end

    def a_troop_attack(actor)
      tg = @mobj_target[actor]
      return if tg < 0
      a_face_target(actor)
      if check_melee_range(actor)
        damage = (@rnd.p_random(SITE_TROOPATTACK) % 8 + 1) * 3
        damage_mobj(tg, actor, actor, damage)
        return
      end
      spawn_missile(actor, tg, MT_TROOPSHOT)
    end

    def a_sarg_attack(actor)
      tg = @mobj_target[actor]
      return if tg < 0
      a_face_target(actor)
      if check_melee_range(actor)
        damage = ((@rnd.p_random(SITE_SARGATTACK) % 10) + 1) * 4
        damage_mobj(tg, actor, actor, damage)
      end
    end

    def a_head_attack(actor)
      tg = @mobj_target[actor]
      return if tg < 0
      a_face_target(actor)
      if check_melee_range(actor)
        damage = (@rnd.p_random(SITE_HEADATTACK) % 6 + 1) * 10
        damage_mobj(tg, actor, actor, damage)
        return
      end
      spawn_missile(actor, tg, MT_HEADSHOT)
    end

    def a_bruis_attack(actor)
      tg = @mobj_target[actor]
      return if tg < 0
      if check_melee_range(actor)
        damage = (@rnd.p_random(SITE_BRUISATTACK) % 8 + 1) * 10
        damage_mobj(tg, actor, actor, damage)
        return
      end
      spawn_missile(actor, tg, MT_BRUISERSHOT)
    end

    def a_skull_attack(actor)
      dest = @mobj_target[actor]
      return if dest < 0
      @mobj_flags[actor] |= Info::MF_SKULLFLY
      a_face_target(actor)
      an = @mobj_angle[actor] >> ANGLETOFINESHIFT
      skullspeed = 20 * FRACUNIT
      @mobj_momx[actor] = fixed_mul(skullspeed, @finesine[an + 2048])
      @mobj_momy[actor] = fixed_mul(skullspeed, @finesine[an])
      dist = aprox_distance(i32(@mobj_x[dest] - @mobj_x[actor]),
                            i32(@mobj_y[dest] - @mobj_y[actor]))
      dist = cdiv(dist, skullspeed)
      dist = 1 if dist < 1
      @mobj_momz[actor] = cdiv(i32(@mobj_z[dest] + (@mobj_height[dest] >> 1) -
                                   @mobj_z[actor]), dist)
    end

    # `P_SpawnMissile`
    def spawn_missile(source, dest, type)
      th = spawn_mobj(@mobj_x[source], @mobj_y[source],
                      i32(@mobj_z[source] + 4 * 8 * FRACUNIT), type)
      @mobj_target[th] = source
      an = point_to_angle2(@mobj_x[source], @mobj_y[source],
                           @mobj_x[dest], @mobj_y[dest])
      if (@mobj_flags[dest] & Info::MF_SHADOW) != 0
        an = bam(an + ((@rnd.p_random(SITE_MISC) - @rnd.p_random(SITE_MISC)) << 20))
      end
      @mobj_angle[th] = an
      a = an >> ANGLETOFINESHIFT
      sp = @info_speed[type]
      @mobj_momx[th] = fixed_mul(sp, @finesine[a + 2048])
      @mobj_momy[th] = fixed_mul(sp, @finesine[a])
      dist = aprox_distance(i32(@mobj_x[dest] - @mobj_x[source]),
                            i32(@mobj_y[dest] - @mobj_y[source]))
      dist = cdiv(dist, sp)
      dist = 1 if dist < 1
      @mobj_momz[th] = cdiv(i32(@mobj_z[dest] - @mobj_z[source]), dist)
      check_missile_spawn(th)
      th
    end

    # `P_CheckMissileSpawn`
    def check_missile_spawn(th)
      @mobj_tics[th] -= @rnd.p_random(SITE_MISSILESPAWN_TICS) & 3
      @mobj_tics[th] = 1 if @mobj_tics[th] < 1
      @mobj_x[th] = i32(@mobj_x[th] + (@mobj_momx[th] >> 1))
      @mobj_y[th] = i32(@mobj_y[th] + (@mobj_momy[th] >> 1))
      @mobj_z[th] = i32(@mobj_z[th] + (@mobj_momz[th] >> 1))
      explode_missile(th) unless try_move(th, @mobj_x[th], @mobj_y[th])
    end

    # -------------------------------------------------------------- lines of fire (p_map)

    # `PTR_AimTraverse`
    def ptr_aim_traverse(idx)
      lv = @level
      if @ic_isaline[idx] != 0
        li = @ic_thing[idx]
        return false if (lv.line_flags[li] & ML_TWOSIDED) == 0
        line_opening(li)
        return false if @openbottom >= @opentop
        dist = fixed_mul(@attackrange, @ic_frac[idx])
        back = lv.line_backsector[li]
        front = lv.line_frontsector[li]
        if back < 0 || lv.sector_floorheight[front] != lv.sector_floorheight[back]
          slope = fixed_div(i32(@openbottom - @shootz), dist)
          @bottomslope = slope if slope > @bottomslope
        end
        if back < 0 || lv.sector_ceilingheight[front] != lv.sector_ceilingheight[back]
          slope = fixed_div(i32(@opentop - @shootz), dist)
          @topslope = slope if slope < @topslope
        end
        return false if @topslope <= @bottomslope
        return true
      end
      th = @ic_thing[idx]
      return true if th == @shootthing
      return true if (@mobj_flags[th] & Info::MF_SHOOTABLE) == 0
      dist = fixed_mul(@attackrange, @ic_frac[idx])
      thingtopslope = fixed_div(i32(@mobj_z[th] + @mobj_height[th] - @shootz), dist)
      return true if thingtopslope < @bottomslope
      thingbottomslope = fixed_div(i32(@mobj_z[th] - @shootz), dist)
      return true if thingbottomslope > @topslope
      thingtopslope = @topslope if thingtopslope > @topslope
      thingbottomslope = @bottomslope if thingbottomslope < @bottomslope
      @aimslope = cdiv(i32(thingtopslope + thingbottomslope), 2)
      @linetarget = th
      false
    end

    # `PTR_ShootTraverse`
    def ptr_shoot_traverse(idx)
      lv = @level
      if @ic_isaline[idx] != 0
        li = @ic_thing[idx]
        shoot_special_line(@shootthing, li) if lv.line_special[li] != 0
        hitline = false
        if (lv.line_flags[li] & ML_TWOSIDED) == 0
          hitline = true
        else
          line_opening(li)
          dist = fixed_mul(@attackrange, @ic_frac[idx])
          back = lv.line_backsector[li]
          front = lv.line_frontsector[li]
          if back < 0
            hitline = true if fixed_div(i32(@openbottom - @shootz), dist) > @aimslope
            hitline = true if !hitline && fixed_div(i32(@opentop - @shootz), dist) < @aimslope
          else
            if lv.sector_floorheight[front] != lv.sector_floorheight[back]
              hitline = true if fixed_div(i32(@openbottom - @shootz), dist) > @aimslope
            end
            if !hitline && lv.sector_ceilingheight[front] != lv.sector_ceilingheight[back]
              hitline = true if fixed_div(i32(@opentop - @shootz), dist) < @aimslope
            end
          end
        end
        return true unless hitline
        frac = i32(@ic_frac[idx] - fixed_div(4 * FRACUNIT, @attackrange))
        x = i32(@trace_x + fixed_mul(@trace_dx, frac))
        y = i32(@trace_y + fixed_mul(@trace_dy, frac))
        z = i32(@shootz + fixed_mul(@aimslope, fixed_mul(frac, @attackrange)))
        front = lv.line_frontsector[li]
        if lv.sector_ceilingpic[front] == lv.skyflatnum
          return false if z > lv.sector_ceilingheight[front]
          back = lv.line_backsector[li]
          return false if back >= 0 && lv.sector_ceilingpic[back] == lv.skyflatnum
        end
        spawn_puff(x, y, z, @attackrange)
        return false
      end
      th = @ic_thing[idx]
      return true if th == @shootthing
      return true if (@mobj_flags[th] & Info::MF_SHOOTABLE) == 0
      dist = fixed_mul(@attackrange, @ic_frac[idx])
      thingtopslope = fixed_div(i32(@mobj_z[th] + @mobj_height[th] - @shootz), dist)
      return true if thingtopslope < @aimslope
      thingbottomslope = fixed_div(i32(@mobj_z[th] - @shootz), dist)
      return true if thingbottomslope > @aimslope
      frac = i32(@ic_frac[idx] - fixed_div(10 * FRACUNIT, @attackrange))
      x = i32(@trace_x + fixed_mul(@trace_dx, frac))
      y = i32(@trace_y + fixed_mul(@trace_dy, frac))
      z = i32(@shootz + fixed_mul(@aimslope, fixed_mul(frac, @attackrange)))
      if (@mobj_flags[th] & Info::MF_NOBLOOD) != 0
        spawn_puff(x, y, z, @attackrange)
      else
        spawn_blood(x, y, z, @la_damage)
      end
      damage_mobj(th, @shootthing, @shootthing, @la_damage) if @la_damage != 0
      false
    end

    # `P_AimLineAttack`
    def aim_line_attack(t1, angle, distance)
      a = angle >> ANGLETOFINESHIFT
      @shootthing = t1
      x2 = i32(@mobj_x[t1] + (distance >> 16) * @finesine[a + 2048])
      y2 = i32(@mobj_y[t1] + (distance >> 16) * @finesine[a])
      @shootz = i32(@mobj_z[t1] + (@mobj_height[t1] >> 1) + 8 * FRACUNIT)
      @topslope = 100 * FRACUNIT / 160
      @bottomslope = -(100 * FRACUNIT / 160)
      @attackrange = distance
      @linetarget = -1
      @traverser = 3
      path_traverse(@mobj_x[t1], @mobj_y[t1], x2, y2, 3)
      @linetarget >= 0 ? @aimslope : 0
    end

    # `P_LineAttack`
    def line_attack(t1, angle, distance, slope, damage)
      a = angle >> ANGLETOFINESHIFT
      @shootthing = t1
      @la_damage = damage
      x2 = i32(@mobj_x[t1] + (distance >> 16) * @finesine[a + 2048])
      y2 = i32(@mobj_y[t1] + (distance >> 16) * @finesine[a])
      @shootz = i32(@mobj_z[t1] + (@mobj_height[t1] >> 1) + 8 * FRACUNIT)
      @attackrange = distance
      @aimslope = slope
      @traverser = 4
      path_traverse(@mobj_x[t1], @mobj_y[t1], x2, y2, 3)
    end

    # `PTR_UseTraverse`
    def ptr_use_traverse(idx)
      li = @ic_thing[idx]
      if @level.line_special[li] == 0
        line_opening(li)
        return false if @openrange <= 0
        return true
      end
      side = point_on_line_side(@mobj_x[@usething], @mobj_y[@usething], li) == 1 ? 1 : 0
      use_special_line(@usething, li, side)
      false
    end

    # `P_UseLines`
    def use_lines
      m = @player_mo
      @usething = m
      a = @mobj_angle[m] >> ANGLETOFINESHIFT
      x1 = @mobj_x[m]
      y1 = @mobj_y[m]
      x2 = i32(x1 + (USERANGE >> 16) * @finesine[a + 2048])
      y2 = i32(y1 + (USERANGE >> 16) * @finesine[a])
      @traverser = 2
      path_traverse(x1, y1, x2, y2, 1)
    end
  end
end
