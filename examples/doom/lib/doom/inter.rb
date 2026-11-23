# doom/lib/doom/inter.rb
#
# Damage, death and picking up items (`p_inter.c`). A mixin included in `Doom::Game`.
#
# `P_DamageMobj` **may draw `P_Random` twice** (reversing the knock-back direction and
# painchance), so for demo matching it weighs as much as the AI.
# `P_KillMobj` also draws once for the death frame's tics.
#
# Picking up items (`P_TouchSpecialThing`) draws no random number, but it **removes mobjs**,
# so it moves the thinker list and the sectors' thinglists. The order of `R_AddSprites`
# depends directly on this.

require_relative "defs"
require_relative "info"

module Doom
  module Inter
    MAXHEALTH_ = 100
    BONUSADD = 6

    # The sprite number (the index in `info.c`'s `sprnames`). Only the pickups placed in
    # E1M5 are needed, but anything missed shows up as a `raise`.
    def touch_special_thing(special, toucher)
      delta = i32(@mobj_z[special] - @mobj_z[toucher])
      return if delta > @mobj_height[toucher] || delta < -8 * FRACUNIT
      return if @pl_health <= 0
      spr = @mobj_sprite[special]
      unless give_by_sprite(spr, special)
        return
      end
      @pl_itemcount += 1 if (@mobj_flags[special] & Info::MF_COUNTITEM) != 0
      remove_mobj(special)
      @pl_bonuscount += BONUSADD
    end

    # The switch of `P_TouchSpecialThing`. false if it cannot be picked up (the mobj stays).
    def give_by_sprite(spr, special)
      name = @sprnames[spr]
      case name
      when "ARM1" then msg(give_armor(1), 1)
      when "ARM2" then msg(give_armor(2), 2)
      when "BON1"
        @pl_message = 3
        @pl_health += 1
        @pl_health = 200 if @pl_health > 200
        @mobj_health[@player_mo] = @pl_health
        true
      when "BON2"
        @pl_message = 4
        @pl_armorpoints += 1
        @pl_armorpoints = 200 if @pl_armorpoints > 200
        @pl_armortype = 1 if @pl_armortype == 0
        true
      when "SOUL"
        @pl_message = 8
        @pl_health += 100
        @pl_health = 200 if @pl_health > 200
        @mobj_health[@player_mo] = @pl_health
        true
      when "MEGA"
        @pl_message = 9
        @pl_health = 200
        @mobj_health[@player_mo] = @pl_health
        give_armor(2)
        true
      when "BKEY" then msg(give_card(0), 10)
      when "YKEY" then msg(give_card(1), 11)
      when "RKEY" then msg(give_card(2), 12)
      when "BSKU" then msg(give_card(3), 13)
      when "YSKU" then msg(give_card(4), 14)
      when "RSKU" then msg(give_card(5), 15)
      when "STIM" then msg(give_body(10), 5)
      when "MEDI"
        # `GOTMEDINEED` is decided by the value **after `P_GiveBody` has added health**
        # (`p_inter.c:474-482`). C does
        #
        #     if (!P_GiveBody (player, 25)) return;
        #     if (player->health < 25) message = GOTMEDINEED; else GOTMEDIKIT;
        #
        # in that order, and `P_GiveBody` has already added 25. **So `GOTMEDINEED`
        # ("a medikit you really needed") never actually appears**: a famous piece of
        # dead code in vanilla. This was first misread as "before adding", and in the
        # 49 frames of DEMO1's tics 3404-3452 **the longer string was drawn in the top
        # 7 lines**.
        ok = give_body(25)
        msg(ok, @pl_health < 25 ? 6 : 7)
      when "PINV" then msg(give_power(PW_INVULNERABILITY), 16)
      when "PSTR" then msg(give_power(PW_STRENGTH), 17)
      when "PINS" then msg(give_power(PW_INVISIBILITY), 18)
      when "SUIT" then msg(give_power(PW_IRONFEET), 19)
      when "PMAP" then msg(give_power(PW_ALLMAP), 20)
      when "PVIS" then msg(give_power(PW_INFRARED), 21)
      when "CLIP"
        msg(give_ammo(0, (@mobj_flags[special] & Info::MF_DROPPED) != 0 ? 0 : 1),
            22)
      when "AMMO" then msg(give_ammo(0, 5), 23)
      when "ROCK" then msg(give_ammo(3, 1), 24)
      when "BROK" then msg(give_ammo(3, 5), 25)
      when "CELL" then msg(give_ammo(2, 1), 26)
      when "CELP" then msg(give_ammo(2, 5), 27)
      when "SHEL" then msg(give_ammo(1, 1), 28)
      when "SBOX" then msg(give_ammo(1, 5), 29)
      when "BPAK" then msg(give_backpack, 30)
      when "MGUN"
        msg(give_weapon(WP_CHAINGUN, (@mobj_flags[special] & Info::MF_DROPPED) != 0),
            31)
      when "CSAW" then msg(give_weapon(WP_CHAINSAW, false), 32)
      when "LAUN" then msg(give_weapon(WP_MISSILE, false), 33)
      when "SHOT"
        msg(give_weapon(WP_SHOTGUN, (@mobj_flags[special] & Info::MF_DROPPED) != 0),
            34)
      else
        raise LevelError, "P_SpecialThing: unknown gettable sprite #{name}"
      end
    end

    # Raises the message only when the item was picked up (`p_inter.c` leaves with `return`).
    def msg(got, text)
      @pl_message = text if got
      got
    end

    def give_armor(armortype)
      hits = armortype * 100
      return false if @pl_armorpoints >= hits
      @pl_armortype = armortype
      @pl_armorpoints = hits
      true
    end

    def give_card(card)
      return false if @pl_cards[card] != 0
      @pl_bonuscount = BONUSADD
      @pl_cards[card] = 1
      true
    end

    def give_body(num)
      return false if @pl_health >= MAXHEALTH_
      @pl_health += num
      @pl_health = MAXHEALTH_ if @pl_health > MAXHEALTH_
      @mobj_health[@player_mo] = @pl_health
      true
    end

    def give_power(power)
      if power == PW_INVULNERABILITY
        @pl_powers[power] = 30 * TICRATE
        return true
      end
      if power == PW_INVISIBILITY
        @pl_powers[power] = 60 * TICRATE
        @mobj_flags[@player_mo] |= Info::MF_SHADOW
        return true
      end
      if power == PW_INFRARED
        @pl_powers[power] = 120 * TICRATE
        return true
      end
      if power == PW_IRONFEET
        @pl_powers[power] = 60 * TICRATE
        return true
      end
      if power == PW_STRENGTH
        give_body(100)
        @pl_powers[power] = 1
        return true
      end
      return false if @pl_powers[power] != 0
      @pl_powers[power] = 1
      true
    end

    # `P_GiveAmmo` (num = the number of clips; 0 means "half").
    def give_ammo(ammo, num)
      return false if ammo == 5
      raise LevelError, "P_GiveAmmo: bad type #{ammo}" if ammo < 0 || ammo > 3
      return false if @pl_ammo[ammo] == @pl_maxammo[ammo]
      if num != 0
        num *= clipammo(ammo)
      else
        num = clipammo(ammo) / 2
      end
      num *= 2 if @skill == 0 || @skill == 4
      oldammo = @pl_ammo[ammo]
      @pl_ammo[ammo] += num
      @pl_ammo[ammo] = @pl_maxammo[ammo] if @pl_ammo[ammo] > @pl_maxammo[ammo]
      return true if oldammo != 0
      # Switch weapons if picking up ammo makes firing possible for the first time
      case ammo
      when 0
        if @pl_readyweapon == WP_FIST
          @pl_pendingweapon = @pl_weaponowned[WP_CHAINGUN] != 0 ? WP_CHAINGUN : WP_PISTOL
        end
      when 1
        if @pl_readyweapon == WP_FIST || @pl_readyweapon == WP_PISTOL
          @pl_pendingweapon = WP_SHOTGUN if @pl_weaponowned[WP_SHOTGUN] != 0
        end
      when 2
        if @pl_readyweapon == WP_FIST || @pl_readyweapon == WP_PISTOL
          @pl_pendingweapon = WP_PLASMA if @pl_weaponowned[WP_PLASMA] != 0
        end
      when 3
        if @pl_readyweapon == WP_FIST
          @pl_pendingweapon = WP_MISSILE if @pl_weaponowned[WP_MISSILE] != 0
        end
      end
      true
    end

    def clipammo(ammo)
      return 10 if ammo == 0
      return 4 if ammo == 1
      return 20 if ammo == 2
      1
    end

    def give_backpack
      unless @pl_backpack != 0
        i = 0
        while i < NUMAMMO
          @pl_maxammo[i] *= 2
          i += 1
        end
        @pl_backpack = 1
      end
      i = 0
      while i < NUMAMMO
        give_ammo(i, 1)
        i += 1
      end
      true
    end

    def give_weapon(weapon, dropped)
      gaveammo = false
      gaveweapon = false
      if @pl_weaponowned[weapon] == 0
        gaveweapon = true
        @pl_weaponowned[weapon] = 1
        @pl_pendingweapon = weapon
      end
      am = @weapon_ammo[weapon]
      if am != 5
        gaveammo = give_ammo(am, dropped ? 1 : 2)
      end
      gaveweapon || gaveammo
    end

    # `P_KillMobj`
    def kill_mobj(source, target)
      @mobj_flags[target] &= ~(Info::MF_SHOOTABLE | Info::MF_FLOAT | Info::MF_SKULLFLY)
      @mobj_flags[target] &= ~Info::MF_NOGRAVITY if @mobj_type[target] != MT_SKULL
      @mobj_flags[target] |= Info::MF_CORPSE | Info::MF_DROPOFF
      @mobj_height[target] >>= 2

      if source >= 0 && @mobj_player[source] >= 0
        @pl_killcount += 1 if (@mobj_flags[target] & Info::MF_COUNTKILL) != 0
      elsif (@mobj_flags[target] & Info::MF_COUNTKILL) != 0
        @pl_killcount += 1
      end

      if @mobj_player[target] >= 0
        @mobj_flags[target] &= ~Info::MF_SOLID
        @pl_playerstate = PST_DEAD
        drop_weapon
      end

      if @mobj_health[target] < -@info_spawnhealth[@mobj_type[target]] &&
         @info_xdeathstate[@mobj_type[target]] != 0
        set_mobj_state(target, @info_xdeathstate[@mobj_type[target]])
      else
        set_mobj_state(target, @info_deathstate[@mobj_type[target]])
      end
      @mobj_tics[target] -= @rnd.p_random(SITE_XDEATH) & 3
      @mobj_tics[target] = 1 if @mobj_tics[target] < 1

      # Dropped items (MT_POSSESSED -> MT_CLIP / MT_SHOTGUY -> MT_SHOTGUN /
      # MT_CHAINGUY -> MT_CHAINGUN). Looked up by `info.c`'s doomednum.
      t = @mobj_type[target]
      item = -1
      # This is **the mobjtype number**, not the doomednum.
      # The doomednums (64/78/74) were written at first, MT_SUPERSHOTGUN (78)
      # dropped, and it failed on `SGN2`.
      item = 63 if t == 1                 # MT_POSSESSED -> MT_CLIP
      item = 77 if t == 2                 # MT_SHOTGUY   -> MT_SHOTGUN
      item = 73 if t == 10                # MT_CHAINGUY  -> MT_CHAINGUN
      return if item < 0
      mo = spawn_mobj(@mobj_x[target], @mobj_y[target], ONFLOORZ, item)
      @mobj_flags[mo] |= Info::MF_DROPPED
    end

    # `P_DamageMobj`. inflictor / source are mobj numbers (-1 = NULL).
    def damage_mobj(target, inflictor, source, damage)
      return if (@mobj_flags[target] & Info::MF_SHOOTABLE) == 0
      return if @mobj_health[target] <= 0
      if (@mobj_flags[target] & Info::MF_SKULLFLY) != 0
        @mobj_momx[target] = 0
        @mobj_momy[target] = 0
        @mobj_momz[target] = 0
      end
      isplayer = @mobj_player[target] >= 0
      damage >>= 1 if isplayer && @skill == 0

      if inflictor >= 0 && (@mobj_flags[target] & Info::MF_NOCLIP) == 0 &&
         (source < 0 || @mobj_player[source] < 0 || @pl_readyweapon != WP_CHAINSAW)
        ang = point_to_angle2(@mobj_x[inflictor], @mobj_y[inflictor],
                              @mobj_x[target], @mobj_y[target])
        thrust = cdiv(damage * (FRACUNIT >> 3) * 100, @info_mass[@mobj_type[target]])
        if damage < 40 && damage > @mobj_health[target] &&
           i32(@mobj_z[target] - @mobj_z[inflictor]) > 64 * FRACUNIT &&
           (@rnd.p_random(SITE_DAMAGE_THRUST) & 1) != 0
          ang = bam(ang + ANG180)
          thrust *= 4
        end
        a = ang >> ANGLETOFINESHIFT
        @mobj_momx[target] = i32(@mobj_momx[target] + fixed_mul(thrust, @finesine[a + 2048]))
        @mobj_momy[target] = i32(@mobj_momy[target] + fixed_mul(thrust, @finesine[a]))
      end

      if isplayer
        if @level.sector_special[@mobj_sector[target]] == 11 && damage >= @mobj_health[target]
          damage = @mobj_health[target] - 1
        end
        return if damage < 1000 && @pl_powers[PW_INVULNERABILITY] != 0
        if @pl_armortype != 0
          saved = @pl_armortype == 1 ? damage / 3 : damage / 2
          if @pl_armorpoints <= saved
            saved = @pl_armorpoints
            @pl_armortype = 0
          end
          @pl_armorpoints -= saved
          damage -= saved
        end
        @pl_health -= damage
        @pl_health = 0 if @pl_health < 0
        @pl_attacker = source
        @pl_damagecount += damage
        @pl_damagecount = 100 if @pl_damagecount > 100
      end

      @mobj_health[target] -= damage
      if @mobj_health[target] <= 0
        kill_mobj(source, target)
        return
      end

      if @rnd.p_random(SITE_PAINCHANCE) < @info_painchance[@mobj_type[target]] &&
         (@mobj_flags[target] & Info::MF_SKULLFLY) == 0
        @mobj_flags[target] |= Info::MF_JUSTHIT
        set_mobj_state(target, @info_painstate[@mobj_type[target]])
      end
      @mobj_reactiontime[target] = 0

      if (@mobj_threshold[target] == 0 || @mobj_type[target] == MT_VILE) &&
         source >= 0 && source != target && @mobj_type[source] != MT_VILE
        @mobj_target[target] = source
        @mobj_threshold[target] = BASETHRESHOLD
        if @mobj_state[target] == @info_spawnstate[@mobj_type[target]] &&
           @info_seestate[@mobj_type[target]] != S_NULL
          set_mobj_state(target, @info_seestate[@mobj_type[target]])
        end
      end
    end
  end
end
