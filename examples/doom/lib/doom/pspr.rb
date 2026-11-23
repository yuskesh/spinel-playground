# doom/lib/doom/pspr.rb
#
# Weapon sprites (`p_pspr.c`). A mixin included in `Doom::Game`.
#
# A psprite **shares** `states[]` with mobjs; only the action functions differ
# (`action.acp2(player, psp)`, with 2 arguments). So there is a
# `dispatch_psp_action` apart from `dispatch_action` (for mobjs).
#
# `states[].misc1` / `misc2` mean something only for psprites (a pair of coordinates).
# That is why `Info.state_misc1` / `state_misc2` were added to the generated tables.
#
# **This is also the side that answers an earlier handover**: before tics ran,
# `psprites[ps_weapon]` had only `S_PISTOL`'s initial frame, and `R_DrawPSprite`'s
# real drawing had never run. With tics running it runs every frame.

require_relative "defs"
require_relative "info"

module Doom
  module Pspr
    PS_WEAPON = 0
    PS_FLASH = 1
    NUMPSPRITES = 2
    LOWERSPEED = 6 * 0x10000
    RAISESPEED = 6 * 0x10000
    WEAPONBOTTOM = 128 * 0x10000
    WEAPONTOP = 32 * 0x10000
    S_CHAIN1 = 52
    S_PLAY_ATK2_ = 155

    def init_psprites
      @psp_state = Array.new(NUMPSPRITES, 0)     # 0 = S_NULL = inactive
      @psp_tics = Array.new(NUMPSPRITES, 0)
      @psp_sx = Array.new(NUMPSPRITES, 0)
      @psp_sy = Array.new(NUMPSPRITES, 0)
      @bulletslope = 0
    end

    # `P_SetPsprite`
    def set_psprite(position, stnum)
      loop do
        if stnum == 0
          @psp_state[position] = 0
          break
        end
        @psp_state[position] = stnum
        @psp_tics[position] = @state_tics[stnum]
        if @state_misc1[stnum] != 0
          @psp_sx[position] = @state_misc1[stnum] << 16
          @psp_sy[position] = @state_misc2[stnum] << 16
        end
        a = @state_action[stnum]
        if a >= 0
          dispatch_psp_action(a, position)
          break if @psp_state[position] == 0
        end
        stnum = @state_nextstate[@psp_state[position]]
        break if @psp_tics[position] != 0
      end
    end

    def dispatch_psp_action(a, psp)
      case a
      when Info::ACT_WEAPONREADY then a_weapon_ready(psp)
      when Info::ACT_LOWER then a_lower(psp)
      when Info::ACT_RAISE then a_raise(psp)
      when Info::ACT_REFIRE then a_refire(psp)
      when Info::ACT_GUNFLASH then a_gun_flash(psp)
      when Info::ACT_FIREPISTOL then a_fire_pistol(psp)
      when Info::ACT_FIRESHOTGUN then a_fire_shotgun(psp)
      when Info::ACT_FIRECGUN then a_fire_cgun(psp)
      when Info::ACT_PUNCH then a_punch(psp)
      when Info::ACT_SAW then a_saw(psp)
      when Info::ACT_CHECKRELOAD then check_ammo
      when Info::ACT_LIGHT0 then @pl_extralight = 0
      when Info::ACT_LIGHT1 then @pl_extralight = 1
      when Info::ACT_LIGHT2 then @pl_extralight = 2
      when Info::ACT_FIREMISSILE then a_fire_missile(psp)
      else
        raise LevelError, "unimplemented weapon action #{a} (psp #{psp})"
      end
    end

    # `P_SetupPsprites`
    def setup_psprites
      i = 0
      while i < NUMPSPRITES
        @psp_state[i] = 0
        i += 1
      end
      @pl_pendingweapon = @pl_readyweapon
      bring_up_weapon
    end

    # `P_BringUpWeapon`
    def bring_up_weapon
      @pl_pendingweapon = @pl_readyweapon if @pl_pendingweapon == WP_NOCHANGE
      newstate = @weapon_upstate[@pl_pendingweapon]
      @pl_pendingweapon = WP_NOCHANGE
      @psp_sy[PS_WEAPON] = WEAPONBOTTOM
      set_psprite(PS_WEAPON, newstate)
    end

    # `P_MovePsprites`
    def move_psprites
      i = 0
      while i < NUMPSPRITES
        if @psp_state[i] != 0 && @psp_tics[i] != -1
          @psp_tics[i] -= 1
          set_psprite(i, @state_nextstate[@psp_state[i]]) if @psp_tics[i] == 0
        end
        i += 1
      end
      @psp_sx[PS_FLASH] = @psp_sx[PS_WEAPON]
      @psp_sy[PS_FLASH] = @psp_sy[PS_WEAPON]
    end

    # `P_CheckAmmo`. This is the shareware version, so plasma / bfg / supershotgun cannot be held.
    def check_ammo
      ammo = @weapon_ammo[@pl_readyweapon]
      count = 1
      return true if ammo == 5 || @pl_ammo[ammo] >= count
      loop do
        if @pl_weaponowned[WP_CHAINGUN] != 0 && @pl_ammo[0] != 0
          @pl_pendingweapon = WP_CHAINGUN
        elsif @pl_weaponowned[WP_SHOTGUN] != 0 && @pl_ammo[1] != 0
          @pl_pendingweapon = WP_SHOTGUN
        elsif @pl_ammo[0] != 0
          @pl_pendingweapon = WP_PISTOL
        elsif @pl_weaponowned[WP_CHAINSAW] != 0
          @pl_pendingweapon = WP_CHAINSAW
        elsif @pl_weaponowned[WP_MISSILE] != 0 && @pl_ammo[3] != 0
          @pl_pendingweapon = WP_MISSILE
        else
          @pl_pendingweapon = WP_FIST
        end
        break if @pl_pendingweapon != WP_NOCHANGE
      end
      set_psprite(PS_WEAPON, @weapon_downstate[@pl_readyweapon])
      false
    end

    # `P_FireWeapon`
    def fire_weapon
      return unless check_ammo
      set_mobj_state(@player_mo, S_PLAY_ATK1)
      set_psprite(PS_WEAPON, @weapon_atkstate[@pl_readyweapon])
      noise_alert(@player_mo, @player_mo)
    end

    # `A_WeaponReady`
    def a_weapon_ready(psp)
      m = @player_mo
      if @mobj_state[m] == S_PLAY_ATK1 || @mobj_state[m] == S_PLAY_ATK2_
        set_mobj_state(m, S_PLAY)
      end
      if @pl_pendingweapon != WP_NOCHANGE || @pl_health == 0
        set_psprite(PS_WEAPON, @weapon_downstate[@pl_readyweapon])
        return
      end
      if (@cmd_buttons & BT_ATTACK) != 0
        if @pl_attackdown == 0 ||
           (@pl_readyweapon != WP_MISSILE && @pl_readyweapon != WP_BFG)
          @pl_attackdown = 1
          fire_weapon
          return
        end
      else
        @pl_attackdown = 0
      end
      angle = (128 * @leveltime) & FINEMASK
      @psp_sx[psp] = i32(FRACUNIT + fixed_mul(@pl_bob, @finesine[angle + 2048]))
      angle &= (FINEANGLES / 2 - 1)
      @psp_sy[psp] = i32(WEAPONTOP + fixed_mul(@pl_bob, @finesine[angle]))
    end

    def a_refire(_psp)
      if (@cmd_buttons & BT_ATTACK) != 0 && @pl_pendingweapon == WP_NOCHANGE &&
         @pl_health != 0
        @pl_refire += 1
        fire_weapon
      else
        @pl_refire = 0
        check_ammo
      end
    end

    def a_lower(psp)
      @psp_sy[psp] = i32(@psp_sy[psp] + LOWERSPEED)
      return if @psp_sy[psp] < WEAPONBOTTOM
      if @pl_playerstate == PST_DEAD
        @psp_sy[psp] = WEAPONBOTTOM
        return
      end
      if @pl_health == 0
        set_psprite(PS_WEAPON, 0)
        return
      end
      @pl_readyweapon = @pl_pendingweapon
      bring_up_weapon
    end

    def a_raise(psp)
      @psp_sy[psp] = i32(@psp_sy[psp] - RAISESPEED)
      return if @psp_sy[psp] > WEAPONTOP
      @psp_sy[psp] = WEAPONTOP
      set_psprite(PS_WEAPON, @weapon_readystate[@pl_readyweapon])
    end

    def a_gun_flash(_psp)
      set_mobj_state(@player_mo, S_PLAY_ATK2_)
      set_psprite(PS_FLASH, @weapon_flashstate[@pl_readyweapon])
    end

    def decrease_ammo(ammonum, amount)
      if ammonum < NUMAMMO
        @pl_ammo[ammonum] -= amount
      else
        @pl_maxammo[ammonum - NUMAMMO] -= amount
      end
    end

    # `P_BulletSlope`
    def bullet_slope(mo)
      an = @mobj_angle[mo]
      @bulletslope = aim_line_attack(mo, an, 16 * 64 * FRACUNIT)
      if @linetarget < 0
        an = bam(an + (1 << 26))
        @bulletslope = aim_line_attack(mo, an, 16 * 64 * FRACUNIT)
        if @linetarget < 0
          an = bam(an - (2 << 26))
          @bulletslope = aim_line_attack(mo, an, 16 * 64 * FRACUNIT)
        end
      end
    end

    # `P_GunShot`
    def gun_shot(mo, accurate)
      damage = 5 * (@rnd.p_random(SITE_GUNSHOT_DAMAGE) % 3 + 1)
      angle = @mobj_angle[mo]
      unless accurate
        angle = bam(angle + ((@rnd.p_random(SITE_GUNSHOT_ANGLE) -
                              @rnd.p_random(SITE_GUNSHOT_ANGLE)) << 18))
      end
      line_attack(mo, angle, MISSILERANGE, @bulletslope, damage)
    end

    def a_fire_pistol(_psp)
      m = @player_mo
      set_mobj_state(m, S_PLAY_ATK2_)
      decrease_ammo(@weapon_ammo[@pl_readyweapon], 1)
      set_psprite(PS_FLASH, @weapon_flashstate[@pl_readyweapon])
      bullet_slope(m)
      gun_shot(m, @pl_refire == 0)
    end

    def a_fire_shotgun(_psp)
      m = @player_mo
      set_mobj_state(m, S_PLAY_ATK2_)
      decrease_ammo(@weapon_ammo[@pl_readyweapon], 1)
      set_psprite(PS_FLASH, @weapon_flashstate[@pl_readyweapon])
      bullet_slope(m)
      i = 0
      while i < 7
        gun_shot(m, false)
        i += 1
      end
    end

    def a_fire_cgun(psp)
      m = @player_mo
      return if @pl_ammo[@weapon_ammo[@pl_readyweapon]] == 0
      set_mobj_state(m, S_PLAY_ATK2_)
      decrease_ammo(@weapon_ammo[@pl_readyweapon], 1)
      set_psprite(PS_FLASH,
                  @weapon_flashstate[@pl_readyweapon] + @psp_state[psp] - S_CHAIN1)
      bullet_slope(m)
      gun_shot(m, @pl_refire == 0)
    end

    def a_punch(_psp)
      m = @player_mo
      damage = (@rnd.p_random(SITE_PUNCH_DAMAGE) % 10 + 1) << 1
      damage *= 10 if @pl_powers[PW_STRENGTH] != 0
      angle = bam(@mobj_angle[m] + ((@rnd.p_random(SITE_PUNCH_ANGLE) -
                                     @rnd.p_random(SITE_PUNCH_ANGLE)) << 18))
      slope = aim_line_attack(m, angle, MELEERANGE)
      line_attack(m, angle, MELEERANGE, slope, damage)
      if @linetarget >= 0
        @mobj_angle[m] = point_to_angle2(@mobj_x[m], @mobj_y[m],
                                         @mobj_x[@linetarget], @mobj_y[@linetarget])
      end
    end

    def a_saw(_psp)
      m = @player_mo
      damage = 2 * (@rnd.p_random(SITE_SAW_DAMAGE) % 10 + 1)
      angle = bam(@mobj_angle[m] + ((@rnd.p_random(SITE_SAW_ANGLE) -
                                     @rnd.p_random(SITE_SAW_ANGLE)) << 18))
      slope = aim_line_attack(m, angle, MELEERANGE + 1)
      line_attack(m, angle, MELEERANGE + 1, slope, damage)
      return if @linetarget < 0
      angle = point_to_angle2(@mobj_x[m], @mobj_y[m],
                              @mobj_x[@linetarget], @mobj_y[@linetarget])
      d = bam(angle - @mobj_angle[m])
      if d > ANG180
        if i32(d) < -(ANG90 / 20)
          @mobj_angle[m] = bam(angle + ANG90 / 21)
        else
          @mobj_angle[m] = bam(@mobj_angle[m] - ANG90 / 20)
        end
      else
        if d > ANG90 / 20
          @mobj_angle[m] = bam(angle - ANG90 / 21)
        else
          @mobj_angle[m] = bam(@mobj_angle[m] + ANG90 / 20)
        end
      end
      @mobj_flags[m] |= Info::MF_JUSTATTACKED
    end

    def a_fire_missile(_psp)
      decrease_ammo(@weapon_ammo[@pl_readyweapon], 1)
      spawn_player_missile(@player_mo, MT_ROCKET)
    end

    # `P_SpawnPlayerMissile` (`p_mobj.c`). The aim tries `P_AimLineAttack`
    # up to 3 times (straight / +1<<26 / -1<<26). **It draws no random number.**
    def spawn_player_missile(source, type)
      an = @mobj_angle[source]
      slope = aim_line_attack(source, an, 16 * 64 * FRACUNIT)
      if @linetarget < 0
        an = bam(an + (1 << 26))
        slope = aim_line_attack(source, an, 16 * 64 * FRACUNIT)
        if @linetarget < 0
          an = bam(an - (2 << 26))
          slope = aim_line_attack(source, an, 16 * 64 * FRACUNIT)
        end
        if @linetarget < 0
          an = @mobj_angle[source]
          slope = 0
        end
      end
      th = spawn_mobj(@mobj_x[source], @mobj_y[source],
                      i32(@mobj_z[source] + 4 * 8 * FRACUNIT), type)
      @mobj_target[th] = source
      @mobj_angle[th] = an
      a = an >> ANGLETOFINESHIFT
      sp = @info_speed[type]
      @mobj_momx[th] = fixed_mul(sp, @finesine[a + 2048])
      @mobj_momy[th] = fixed_mul(sp, @finesine[a])
      @mobj_momz[th] = fixed_mul(sp, slope)
      check_missile_spawn(th)
    end

    # `P_DropWeapon`
    def drop_weapon
      set_psprite(PS_WEAPON, @weapon_downstate[@pl_readyweapon])
    end
  end
end
