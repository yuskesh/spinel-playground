# doom/lib/doom/specials.rb
#
# Sector / line specials (`p_spec.c` + `p_lights.c` + `p_doors.c` + `p_plats.c`).
# A mixin included in `Doom::Game`.
#
# The scope was set by **measuring E1M5 (= DEMO1's map)**:
#
#   sector special: 0×113 / 1 (flash)×2 / 2 (strobe fast)×4 /
#                   7 (nukage)×7 / 8 (glow)×8 / 9 (secret)×9
#   line special:   1, 2, 11, 22, 26, 27, 31, 62, 70, 88, 90, 91, 97, 98, 103
#
# So the thinkers standing at the start of the level are **14** (flash 2 + strobe 4 + glow 8),
# matching the reference implementation's thinker count 230 = mobj 216 + 14.
# Only the 2 flashes and 4 strobes draw `P_Random` (6 times together), and
# these are 6 of the 377 at tic 0.
#
# **Reaching a special that is not implemented fails loudly.**
# The other side of the drawing stages' lesson ("implemented" is not "ran"):
# here, not quietly ignoring "not written yet" is the insurance for determinism.

require_relative "defs"
require_relative "info"

module Doom
  module Specials
    STROBEBRIGHT = 5
    FASTDARK = 15
    SLOWDARK = 35
    GLOWSPEED = 8

    def spawn_specials
      lv = @level
      init_light_arrays
      # ---- sectors
      i = 0
      while i < lv.num_sectors
        sp = lv.sector_special[i]
        if sp != 0
          case sp
          when 1 then spawn_light_flash(i)
          when 2 then spawn_strobe_flash(i, FASTDARK, 0)
          when 3 then spawn_strobe_flash(i, SLOWDARK, 0)
          when 4
            spawn_strobe_flash(i, FASTDARK, 0)
            lv.sector_special[i] = 4
          when 8 then spawn_glowing_light(i)
          when 9 then @totalsecret += 1
          when 10 then raise LevelError, "sector special 10 (door close in 30) not implemented"
          when 12 then spawn_strobe_flash(i, SLOWDARK, 1)
          when 13 then spawn_strobe_flash(i, FASTDARK, 1)
          when 14 then raise LevelError, "sector special 14 (door raise in 5 min) not implemented"
          when 17 then spawn_fire_flicker(i)
          end
        end
        i += 1
      end
      # ---- lines (48 = scrolling wall)
      @linespecials = []
      @numlinespecials = 0
      i = 0
      while i < lv.num_lines
        if lv.line_special[i] == 48
          @linespecials[@numlinespecials] = i
          @numlinespecials += 1
        end
        i += 1
      end
      # ---- platforms / buttons
      @activeplats = Array.new(MAXPLATS, -1)
      @button_line = Array.new(MAXBUTTONS, -1)
      @button_where = Array.new(MAXBUTTONS, 0)
      @button_texture = Array.new(MAXBUTTONS, 0)
      @button_timer = Array.new(MAXBUTTONS, 0)
      @sector_specialdata = Array.new(lv.num_sectors, -1)
      init_door_arrays
      init_plat_arrays
      init_switch_list
    end

    def init_light_arrays
      n = 64
      @lf_sector = Array.new(n, 0)
      @lf_count = Array.new(n, 0)
      @lf_maxlight = Array.new(n, 0)
      @lf_minlight = Array.new(n, 0)
      @lf_maxtime = Array.new(n, 0)
      @lf_mintime = Array.new(n, 0)
      @lf_n = 0
      @st_sector = Array.new(n, 0)
      @st_count = Array.new(n, 0)
      @st_minlight = Array.new(n, 0)
      @st_maxlight = Array.new(n, 0)
      @st_darktime = Array.new(n, 0)
      @st_brighttime = Array.new(n, 0)
      @st_n = 0
      @gl_sector = Array.new(n, 0)
      @gl_minlight = Array.new(n, 0)
      @gl_maxlight = Array.new(n, 0)
      @gl_direction = Array.new(n, 0)
      @gl_n = 0
      @ff_sector = Array.new(n, 0)
      @ff_count = Array.new(n, 0)
      @ff_maxlight = Array.new(n, 0)
      @ff_minlight = Array.new(n, 0)
      @ff_n = 0
    end

    # `getNextSector`
    def next_sector(line, sec)
      lv = @level
      return -1 if (lv.line_flags[line] & ML_TWOSIDED) == 0
      return lv.line_backsector[line] if lv.line_frontsector[line] == sec
      lv.line_frontsector[line]
    end

    # `P_FindMinSurroundingLight`
    def find_min_surrounding_light(sec, max)
      lv = @level
      min = max
      c = lv.sector_linecount[sec]
      o = lv.sector_lineofs[sec]
      i = 0
      while i < c
        check = next_sector(lv.sector_lines[o + i], sec)
        if check >= 0 && lv.sector_lightlevel[check] < min
          min = lv.sector_lightlevel[check]
        end
        i += 1
      end
      min
    end

    # `EV_LightTurnOn` (`p_lights.c`). E1M3's walk special 35 needed it.
    #
    # **`bright` is a function argument, but it is rewritten inside the loop and carried
    # over to the next sector**: when `bright == 0` ("find the brightest neighbour") and it
    # once becomes non-0, every later sector matching the tag **uses that value without
    # searching**. Vanilla's implementation does that (matched to the function the pinned
    # build compiles). Ruby reproduces it by running the same one
    # local.
    def ev_light_turn_on(line, bright)
      lv = @level
      b = bright
      i = 0
      while i < lv.num_sectors
        if lv.sector_tagno[i] == lv.line_tagno[line]
          if b == 0
            c = lv.sector_linecount[i]
            o = lv.sector_lineofs[i]
            j = 0
            while j < c
              temp = next_sector(lv.sector_lines[o + j], i)
              b = lv.sector_lightlevel[temp] if temp >= 0 && lv.sector_lightlevel[temp] > b
              j += 1
            end
          end
          lv.sector_lightlevel[i] = b
        end
        i += 1
      end
    end

    # ------------------------------------------------------------------- lights

    def spawn_light_flash(sec)
      lv = @level
      lv.sector_special[sec] = 0
      k = @lf_n
      @lf_n += 1
      add_thinker(TH_LIGHTFLASH, k)
      @lf_sector[k] = sec
      @lf_maxlight[k] = lv.sector_lightlevel[sec]
      @lf_minlight[k] = find_min_surrounding_light(sec, lv.sector_lightlevel[sec])
      @lf_maxtime[k] = 64
      @lf_mintime[k] = 7
      @lf_count[k] = (@rnd.p_random(SITE_SPAWNLIGHTFLASH) & 64) + 1
    end

    def t_light_flash(k)
      lv = @level
      @lf_count[k] -= 1
      return if @lf_count[k] != 0
      sec = @lf_sector[k]
      if lv.sector_lightlevel[sec] == @lf_maxlight[k]
        lv.sector_lightlevel[sec] = @lf_minlight[k]
        @lf_count[k] = (@rnd.p_random(SITE_LIGHTFLASH_MIN) & @lf_mintime[k]) + 1
      else
        lv.sector_lightlevel[sec] = @lf_maxlight[k]
        @lf_count[k] = (@rnd.p_random(SITE_LIGHTFLASH_MAX) & @lf_maxtime[k]) + 1
      end
    end

    def spawn_strobe_flash(sec, fast_or_slow, in_sync)
      lv = @level
      k = @st_n
      @st_n += 1
      add_thinker(TH_STROBE, k)
      @st_sector[k] = sec
      @st_darktime[k] = fast_or_slow
      @st_brighttime[k] = STROBEBRIGHT
      @st_maxlight[k] = lv.sector_lightlevel[sec]
      @st_minlight[k] = find_min_surrounding_light(sec, lv.sector_lightlevel[sec])
      @st_minlight[k] = 0 if @st_minlight[k] == @st_maxlight[k]
      lv.sector_special[sec] = 0
      if in_sync == 0
        @st_count[k] = (@rnd.p_random(SITE_SPAWNSTROBE) & 7) + 1
      else
        @st_count[k] = 1
      end
    end

    def t_strobe_flash(k)
      lv = @level
      @st_count[k] -= 1
      return if @st_count[k] != 0
      sec = @st_sector[k]
      if lv.sector_lightlevel[sec] == @st_minlight[k]
        lv.sector_lightlevel[sec] = @st_maxlight[k]
        @st_count[k] = @st_brighttime[k]
      else
        lv.sector_lightlevel[sec] = @st_minlight[k]
        @st_count[k] = @st_darktime[k]
      end
    end

    def spawn_glowing_light(sec)
      lv = @level
      k = @gl_n
      @gl_n += 1
      add_thinker(TH_GLOW, k)
      @gl_sector[k] = sec
      @gl_minlight[k] = find_min_surrounding_light(sec, lv.sector_lightlevel[sec])
      @gl_maxlight[k] = lv.sector_lightlevel[sec]
      @gl_direction[k] = -1
      lv.sector_special[sec] = 0
    end

    def t_glow(k)
      lv = @level
      sec = @gl_sector[k]
      if @gl_direction[k] == -1
        lv.sector_lightlevel[sec] -= GLOWSPEED
        if lv.sector_lightlevel[sec] <= @gl_minlight[k]
          lv.sector_lightlevel[sec] += GLOWSPEED
          @gl_direction[k] = 1
        end
      elsif @gl_direction[k] == 1
        lv.sector_lightlevel[sec] += GLOWSPEED
        if lv.sector_lightlevel[sec] >= @gl_maxlight[k]
          lv.sector_lightlevel[sec] -= GLOWSPEED
          @gl_direction[k] = -1
        end
      end
    end

    def spawn_fire_flicker(sec)
      lv = @level
      lv.sector_special[sec] = 0
      k = @ff_n
      @ff_n += 1
      add_thinker(TH_FIREFLICKER, k)
      @ff_sector[k] = sec
      @ff_maxlight[k] = lv.sector_lightlevel[sec]
      @ff_minlight[k] = find_min_surrounding_light(sec, lv.sector_lightlevel[sec]) + 16
      @ff_count[k] = 4
    end

    def t_fire_flicker(k)
      lv = @level
      @ff_count[k] -= 1
      return if @ff_count[k] != 0
      amount = (@rnd.p_random(SITE_FIREFLICKER) & 3) * 16
      sec = @ff_sector[k]
      if lv.sector_lightlevel[sec] - amount < @ff_minlight[k]
        lv.sector_lightlevel[sec] = @ff_minlight[k]
      else
        lv.sector_lightlevel[sec] = @ff_maxlight[k] - amount
      end
      @ff_count[k] = 4
    end

    # -------------------------------------------------------- P_UpdateSpecials

    def update_specials
      lv = @level
      # Animated textures / flats (`anims`). Rewrites the translation table.
      @textures.animate(@leveltime) unless @textures.nil?
      # Scrolling walls (special 48)
      i = 0
      while i < @numlinespecials
        line = @linespecials[i]
        s = lv.line_side0[line]
        lv.side_textureoffset[s] = i32(lv.side_textureoffset[s] + FRACUNIT)
        i += 1
      end
      # Buttons
      i = 0
      while i < MAXBUTTONS
        if @button_timer[i] != 0
          @button_timer[i] -= 1
          if @button_timer[i] == 0
            ld = @button_line[i]
            s = lv.line_side0[ld]
            case @button_where[i]
            when 0 then lv.side_toptexture[s] = @button_texture[i]
            when 1 then lv.side_midtexture[s] = @button_texture[i]
            when 2 then lv.side_bottomtexture[s] = @button_texture[i]
            end
            @button_line[i] = -1
            @button_where[i] = 0
            @button_texture[i] = 0
          end
        end
        i += 1
      end
    end

    # `P_PlayerInSpecialSector`
    def player_in_special_sector
      lv = @level
      m = @player_mo
      sec = @mobj_sector[m]
      return if @mobj_z[m] != lv.sector_floorheight[sec]
      case lv.sector_special[sec]
      when 5
        if @pl_powers[PW_IRONFEET] == 0 && (@leveltime & 0x1f) == 0
          damage_mobj(m, -1, -1, 10)
        end
      when 7
        if @pl_powers[PW_IRONFEET] == 0 && (@leveltime & 0x1f) == 0
          damage_mobj(m, -1, -1, 5)
        end
      when 16, 4
        if @pl_powers[PW_IRONFEET] == 0 || @rnd.p_random(SITE_PLAYERINSPECIAL) < 5
          damage_mobj(m, -1, -1, 20) if (@leveltime & 0x1f) == 0
        end
      when 9
        @pl_secretcount += 1
        lv.sector_special[sec] = 0
      when 11
        damage_mobj(m, -1, -1, 20) if (@leveltime & 0x1f) == 0
        raise LevelError, "E1M8 exit sector (special 11) reached" if @pl_health <= 10
      else
        raise LevelError, "unknown sector special #{lv.sector_special[sec]}"
      end
    end

    # ------------------------------------------------------- raising and lowering sector planes

    # `T_MovePlane` (`p_floor.c`). Returns 0 = ok / 1 = crushed / 2 = pastdest.
    # `floor_or_ceiling` is 0 = floor / 1 = ceiling.
    def move_plane(sec, speed, dest, crush, floor_or_ceiling, direction)
      lv = @level
      if floor_or_ceiling == 0
        if direction == -1
          if i32(lv.sector_floorheight[sec] - speed) < dest
            lastpos = lv.sector_floorheight[sec]
            lv.sector_floorheight[sec] = dest
            if change_sector(sec, crush)
              lv.sector_floorheight[sec] = lastpos
              change_sector(sec, crush)
            end
            return 2
          end
          lastpos = lv.sector_floorheight[sec]
          lv.sector_floorheight[sec] = i32(lastpos - speed)
          if change_sector(sec, crush)
            lv.sector_floorheight[sec] = lastpos
            change_sector(sec, crush)
            return 1
          end
        elsif direction == 1
          if i32(lv.sector_floorheight[sec] + speed) > dest
            lastpos = lv.sector_floorheight[sec]
            lv.sector_floorheight[sec] = dest
            if change_sector(sec, crush)
              lv.sector_floorheight[sec] = lastpos
              change_sector(sec, crush)
            end
            return 2
          end
          lastpos = lv.sector_floorheight[sec]
          lv.sector_floorheight[sec] = i32(lastpos + speed)
          if change_sector(sec, crush)
            return 1 if crush
            lv.sector_floorheight[sec] = lastpos
            change_sector(sec, crush)
            return 1
          end
        end
      else
        if direction == -1
          if i32(lv.sector_ceilingheight[sec] - speed) < dest
            lastpos = lv.sector_ceilingheight[sec]
            lv.sector_ceilingheight[sec] = dest
            if change_sector(sec, crush)
              lv.sector_ceilingheight[sec] = lastpos
              change_sector(sec, crush)
            end
            return 2
          end
          lastpos = lv.sector_ceilingheight[sec]
          lv.sector_ceilingheight[sec] = i32(lastpos - speed)
          if change_sector(sec, crush)
            return 1 if crush
            lv.sector_ceilingheight[sec] = lastpos
            change_sector(sec, crush)
            return 1
          end
        elsif direction == 1
          if i32(lv.sector_ceilingheight[sec] + speed) > dest
            lastpos = lv.sector_ceilingheight[sec]
            lv.sector_ceilingheight[sec] = dest
            if change_sector(sec, crush)
              lv.sector_ceilingheight[sec] = lastpos
              change_sector(sec, crush)
            end
            return 2
          end
          lv.sector_ceilingheight[sec] = i32(lv.sector_ceilingheight[sec] + speed)
          change_sector(sec, crush)
        end
      end
      0
    end

    # `P_ChangeSector` + `PIT_ChangeSector` (`p_map.c`).
    def change_sector(sec, crunch)
      lv = @level
      @nofit = false
      @crushchange = crunch
      x = lv.sector_blockbox[sec * 4 + 2]
      right = lv.sector_blockbox[sec * 4 + 3]
      while x <= right
        y = lv.sector_blockbox[sec * 4 + 1]
        top = lv.sector_blockbox[sec * 4]
        while y <= top
          block_things_iterator_changesector(x, y)
          y += 1
        end
        x += 1
      end
      @nofit
    end

    def block_things_iterator_changesector(x, y)
      lv = @level
      return if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      m = @blocklinks[y * lv.bmapwidth + x]
      while m >= 0
        nxt = @mobj_bnext[m]
        pit_change_sector(m)
        m = nxt
      end
    end

    def pit_change_sector(thing)
      return if thing_height_clip(thing)
      if @mobj_health[thing] <= 0
        set_mobj_state(thing, S_GIBS)
        @mobj_flags[thing] &= ~Info::MF_SOLID
        @mobj_height[thing] = 0
        @mobj_radius[thing] = 0
        return
      end
      if (@mobj_flags[thing] & Info::MF_DROPPED) != 0
        remove_mobj(thing)
        return
      end
      return if (@mobj_flags[thing] & Info::MF_SHOOTABLE) == 0
      @nofit = true
      if @crushchange && (@leveltime & 3) == 0
        damage_mobj(thing, -1, -1, 10)
        mo = spawn_mobj(@mobj_x[thing], @mobj_y[thing],
                        i32(@mobj_z[thing] + @mobj_height[thing] / 2), MT_BLOOD)
        @mobj_momx[mo] = i32((@rnd.p_random(SITE_MISC) - @rnd.p_random(SITE_MISC)) << 12)
        @mobj_momy[mo] = i32((@rnd.p_random(SITE_MISC) - @rnd.p_random(SITE_MISC)) << 12)
      end
    end

    # `P_FindLowestCeilingSurrounding`
    def find_lowest_ceiling_surrounding(sec)
      lv = @level
      height = 0x7fffffff
      c = lv.sector_linecount[sec]
      o = lv.sector_lineofs[sec]
      i = 0
      while i < c
        other = next_sector(lv.sector_lines[o + i], sec)
        if other >= 0 && lv.sector_ceilingheight[other] < height
          height = lv.sector_ceilingheight[other]
        end
        i += 1
      end
      height
    end

    # `P_FindSectorFromLineTag`
    def find_sector_from_line_tag(line, start)
      lv = @level
      i = start + 1
      while i < lv.num_sectors
        return i if lv.sector_tagno[i] == lv.line_tagno[line]
        i += 1
      end
      -1
    end

    # ------------------------------------------------------------------- doors

    VDOORSPEED = 2 * 0x10000
    VDOORWAIT = 150
    VLD_NORMAL = 0
    VLD_CLOSE30 = 1
    VLD_CLOSE = 2
    VLD_OPEN = 3
    VLD_RAISEIN5MINS = 4

    def init_door_arrays
      n = 64
      @dr_sector = Array.new(n, 0)
      @dr_type = Array.new(n, 0)
      @dr_topheight = Array.new(n, 0)
      @dr_speed = Array.new(n, 0)
      @dr_direction = Array.new(n, 0)
      @dr_topwait = Array.new(n, 0)
      @dr_topcountdown = Array.new(n, 0)
      @dr_th = Array.new(n, -1)
      @dr_n = 0
    end

    def new_door(sec)
      k = @dr_n
      @dr_n += 1
      raise LevelError, "too many doors" if k >= @dr_sector.length
      @dr_th[k] = add_thinker(TH_DOOR, k)
      @sector_specialdata[sec] = @dr_th[k]
      @dr_sector[k] = sec
      k
    end

    # `T_VerticalDoor`
    def t_vertical_door(k)
      sec = @dr_sector[k]
      d = @dr_direction[k]
      if d == 0
        @dr_topcountdown[k] -= 1
        if @dr_topcountdown[k] == 0
          @dr_direction[k] = -1 if @dr_type[k] == VLD_NORMAL
          @dr_direction[k] = 1 if @dr_type[k] == VLD_CLOSE30
        end
      elsif d == 2
        @dr_topcountdown[k] -= 1
        if @dr_topcountdown[k] == 0 && @dr_type[k] == VLD_RAISEIN5MINS
          @dr_direction[k] = 1
          @dr_type[k] = VLD_NORMAL
        end
      elsif d == -1
        res = move_plane(sec, @dr_speed[k], @level.sector_floorheight[sec], false, 1, -1)
        if res == 2
          if @dr_type[k] == VLD_NORMAL || @dr_type[k] == VLD_CLOSE
            @sector_specialdata[sec] = -1
            remove_thinker(@dr_th[k])
          elsif @dr_type[k] == VLD_CLOSE30
            @dr_direction[k] = 0
            @dr_topcountdown[k] = TICRATE * 30
          end
        elsif res == 1
          @dr_direction[k] = 1 unless @dr_type[k] == VLD_CLOSE
        end
      elsif d == 1
        res = move_plane(sec, @dr_speed[k], @dr_topheight[k], false, 1, 1)
        if res == 2
          if @dr_type[k] == VLD_NORMAL
            @dr_direction[k] = 0
            @dr_topcountdown[k] = @dr_topwait[k]
          elsif @dr_type[k] == VLD_CLOSE30 || @dr_type[k] == VLD_OPEN
            @sector_specialdata[sec] = -1
            remove_thinker(@dr_th[k])
          end
        end
      end
    end

    # `EV_DoDoor` (a door looked up by tag). Returns whether even one moved.
    def ev_do_door(line, type)
      lv = @level
      secnum = -1
      rtn = false
      loop do
        secnum = find_sector_from_line_tag(line, secnum)
        break if secnum < 0
        next if @sector_specialdata[secnum] >= 0
        rtn = true
        k = new_door(secnum)
        @dr_type[k] = type
        @dr_topwait[k] = VDOORWAIT
        @dr_speed[k] = VDOORSPEED
        if type == VLD_CLOSE
          @dr_topheight[k] = i32(find_lowest_ceiling_surrounding(secnum) - 4 * FRACUNIT)
          @dr_direction[k] = -1
        elsif type == VLD_CLOSE30
          @dr_topheight[k] = lv.sector_ceilingheight[secnum]
          @dr_direction[k] = -1
        else
          @dr_direction[k] = 1
          @dr_topheight[k] = i32(find_lowest_ceiling_surrounding(secnum) - 4 * FRACUNIT)
        end
      end
      rtn
    end

    # `EV_VerticalDoor` (a manual door).
    def ev_vertical_door(line, thing)
      lv = @level
      sp = lv.line_special[line]
      isplayer = @mobj_player[thing] >= 0
      # locked
      if sp == 26 || sp == 32
        return unless isplayer
        if @pl_cards[0] == 0 && @pl_cards[3] == 0
          @pl_message = sp == 26 ? 35 :
                                   38
          return
        end
      elsif sp == 27 || sp == 34
        return unless isplayer
        if @pl_cards[1] == 0 && @pl_cards[4] == 0
          @pl_message = sp == 27 ? 36 :
                                   39
          return
        end
      elsif sp == 28 || sp == 33
        return unless isplayer
        if @pl_cards[2] == 0 && @pl_cards[5] == 0
          @pl_message = sp == 28 ? 37 :
                                   40
          return
        end
      end
      # `sides[line->sidenum[side^1]].sector`: side is always 0, so the back side
      sec = lv.side_sector[lv.line_side1[line]]
      if @sector_specialdata[sec] >= 0
        th = @sector_specialdata[sec]
        if sp == 1 || sp == 26 || sp == 27 || sp == 28 || sp == 117
          k = @th_data[th]
          if @th_func[th] == TH_DOOR
            if @dr_direction[k] == -1
              @dr_direction[k] = 1
            else
              return unless isplayer
              @dr_direction[k] = -1
            end
          elsif @th_func[th] == TH_PLAT
            # Vanilla's famous cross-reference bug (noted by Chocolate Doom).
            # It does not happen in E1M5, but fails loudly so that it would be noticed.
            raise LevelError, "EV_VerticalDoor: sector #{sec} specialdata is a plat"
          else
            raise LevelError, "EV_VerticalDoor: sector #{sec} specialdata is not a door"
          end
          return
        end
      end
      k = new_door(sec)
      @dr_direction[k] = 1
      @dr_speed[k] = VDOORSPEED
      @dr_topwait[k] = VDOORWAIT
      if sp == 1 || sp == 26 || sp == 27 || sp == 28
        @dr_type[k] = VLD_NORMAL
      elsif sp == 31 || sp == 32 || sp == 33 || sp == 34
        @dr_type[k] = VLD_OPEN
        lv.line_special[line] = 0
      else
        raise LevelError, "EV_VerticalDoor: unhandled special #{sp}"
      end
      @dr_topheight[k] = i32(find_lowest_ceiling_surrounding(sec) - 4 * FRACUNIT)
    end

    # ------------------------------------------------------------ platforms

    PLATSPEED = 0x10000
    PLATWAIT = 3
    PLAT_UP = 0
    PLAT_DOWN = 1
    PLAT_WAITING = 2
    PLAT_INSTASIS = 3
    PT_PERPETUAL = 0
    PT_DOWNWAITUPSTAY = 1
    PT_RAISEANDCHANGE = 2
    PT_RAISETONEARESTANDCHANGE = 3

    def init_plat_arrays
      n = 64
      @pl_sector = Array.new(n, 0)
      @pl_speed = Array.new(n, 0)
      @pl_low = Array.new(n, 0)
      @pl_high = Array.new(n, 0)
      @pl_wait = Array.new(n, 0)
      @pl_count = Array.new(n, 0)
      @pl_status = Array.new(n, 0)
      @pl_oldstatus = Array.new(n, 0)
      @pl_crush = Array.new(n, 0)
      @pl_tag = Array.new(n, 0)
      @pl_type = Array.new(n, 0)
      @pl_th = Array.new(n, -1)
      @pl_n = 0
      # floor / ceiling thinker
      @fl_sector = Array.new(n, 0)
      @fl_type = Array.new(n, 0)
      @fl_crush = Array.new(n, false)
      @fl_direction = Array.new(n, 0)
      @fl_newspecial = Array.new(n, 0)
      @fl_texture = Array.new(n, 0)
      @fl_dest = Array.new(n, 0)
      @fl_speed = Array.new(n, 0)
      @fl_th = Array.new(n, -1)
      @fl_n = 0
    end

    def find_lowest_floor_surrounding(sec)
      lv = @level
      floor = lv.sector_floorheight[sec]
      c = lv.sector_linecount[sec]
      o = lv.sector_lineofs[sec]
      i = 0
      while i < c
        other = next_sector(lv.sector_lines[o + i], sec)
        floor = lv.sector_floorheight[other] if other >= 0 && lv.sector_floorheight[other] < floor
        i += 1
      end
      floor
    end

    def find_highest_floor_surrounding(sec)
      lv = @level
      floor = -500 * FRACUNIT
      c = lv.sector_linecount[sec]
      o = lv.sector_lineofs[sec]
      i = 0
      while i < c
        other = next_sector(lv.sector_lines[o + i], sec)
        floor = lv.sector_floorheight[other] if other >= 0 && lv.sector_floorheight[other] > floor
        i += 1
      end
      floor
    end

    # `P_FindNextHighestFloor`. Vanilla **emulates** a stack overflow (21 or more
    # adjacent sectors), but this port fails past 20.
    def find_next_highest_floor(sec, currentheight)
      lv = @level
      height = currentheight
      c = lv.sector_linecount[sec]
      o = lv.sector_lineofs[sec]
      h = 0
      minh = 0
      i = 0
      while i < c
        other = next_sector(lv.sector_lines[o + i], sec)
        if other >= 0 && lv.sector_floorheight[other] > height
          if h >= 20
            raise LevelError, "sector #{sec} has more than 20 adjoining higher sectors"
          end
          v = lv.sector_floorheight[other]
          minh = v if h == 0 || v < minh
          h += 1
        end
        i += 1
      end
      h == 0 ? currentheight : minh
    end

    def t_plat_raise(k)
      lv = @level
      sec = @pl_sector[k]
      st = @pl_status[k]
      if st == PLAT_UP
        res = move_plane(sec, @pl_speed[k], @pl_high[k], @pl_crush[k] != 0, 0, 1)
        if res == 1 && @pl_crush[k] == 0
          @pl_count[k] = @pl_wait[k]
          @pl_status[k] = PLAT_DOWN
        elsif res == 2
          @pl_count[k] = @pl_wait[k]
          @pl_status[k] = PLAT_WAITING
          t = @pl_type[k]
          if t == PT_DOWNWAITUPSTAY || t == PT_RAISEANDCHANGE ||
             t == PT_RAISETONEARESTANDCHANGE
            remove_active_plat(k)
          end
        end
      elsif st == PLAT_DOWN
        res = move_plane(sec, @pl_speed[k], @pl_low[k], false, 0, -1)
        if res == 2
          @pl_count[k] = @pl_wait[k]
          @pl_status[k] = PLAT_WAITING
        end
      elsif st == PLAT_WAITING
        @pl_count[k] -= 1
        if @pl_count[k] == 0
          @pl_status[k] = lv.sector_floorheight[sec] == @pl_low[k] ? PLAT_UP : PLAT_DOWN
        end
      end
    end

    def add_active_plat(k)
      i = 0
      while i < MAXPLATS
        if @activeplats[i] < 0
          @activeplats[i] = k
          return
        end
        i += 1
      end
      raise LevelError, "P_AddActivePlat: no more plats"
    end

    def remove_active_plat(k)
      i = 0
      while i < MAXPLATS
        if @activeplats[i] == k
          @sector_specialdata[@pl_sector[k]] = -1
          remove_thinker(@pl_th[k])
          @activeplats[i] = -1
          return
        end
        i += 1
      end
      raise LevelError, "P_RemoveActivePlat: can't find plat"
    end

    def ev_do_plat(line, type, amount)
      lv = @level
      secnum = -1
      rtn = false
      loop do
        secnum = find_sector_from_line_tag(line, secnum)
        break if secnum < 0
        next if @sector_specialdata[secnum] >= 0
        rtn = true
        k = @pl_n
        @pl_n += 1
        raise LevelError, "too many plats" if k >= @pl_sector.length
        @pl_th[k] = add_thinker(TH_PLAT, k)
        @pl_type[k] = type
        @pl_sector[k] = secnum
        @sector_specialdata[secnum] = @pl_th[k]
        @pl_crush[k] = 0
        @pl_tag[k] = lv.line_tagno[line]
        if type == PT_RAISETONEARESTANDCHANGE
          @pl_speed[k] = PLATSPEED / 2
          lv.sector_floorpic[secnum] = lv.sector_floorpic[lv.side_sector[lv.line_side0[line]]]
          @pl_high[k] = find_next_highest_floor(secnum, lv.sector_floorheight[secnum])
          @pl_wait[k] = 0
          @pl_status[k] = PLAT_UP
          lv.sector_special[secnum] = 0
        elsif type == PT_RAISEANDCHANGE
          @pl_speed[k] = PLATSPEED / 2
          lv.sector_floorpic[secnum] = lv.sector_floorpic[lv.side_sector[lv.line_side0[line]]]
          @pl_high[k] = i32(lv.sector_floorheight[secnum] + amount * FRACUNIT)
          @pl_wait[k] = 0
          @pl_status[k] = PLAT_UP
        elsif type == PT_DOWNWAITUPSTAY
          @pl_speed[k] = PLATSPEED * 4
          @pl_low[k] = find_lowest_floor_surrounding(secnum)
          @pl_low[k] = lv.sector_floorheight[secnum] if @pl_low[k] > lv.sector_floorheight[secnum]
          @pl_high[k] = lv.sector_floorheight[secnum]
          @pl_wait[k] = TICRATE * PLATWAIT
          @pl_status[k] = PLAT_DOWN
        else
          raise LevelError, "EV_DoPlat: type #{type} not implemented"
        end
        add_active_plat(k)
      end
      rtn
    end

    # ------------------------------------------------------------------- floors

    FLOORSPEED = 0x10000
    FT_LOWERFLOOR = 0
    FT_LOWERFLOORTOLOWEST = 1
    FT_TURBOLOWER = 2
    FT_RAISEFLOOR = 3
    FT_RAISEFLOORTONEAREST = 4

    def t_move_floor(k)
      sec = @fl_sector[k]
      res = move_plane(sec, @fl_speed[k], @fl_dest[k], @fl_crush[k], 0, @fl_direction[k])
      if res == 2
        @sector_specialdata[sec] = -1
        remove_thinker(@fl_th[k])
      end
    end

    def ev_do_floor(line, floortype)
      lv = @level
      secnum = -1
      rtn = false
      loop do
        secnum = find_sector_from_line_tag(line, secnum)
        break if secnum < 0
        next if @sector_specialdata[secnum] >= 0
        rtn = true
        k = @fl_n
        @fl_n += 1
        raise LevelError, "too many floors" if k >= @fl_sector.length
        @fl_th[k] = add_thinker(TH_FLOOR, k)
        @sector_specialdata[secnum] = @fl_th[k]
        @fl_type[k] = floortype
        @fl_crush[k] = false
        @fl_sector[k] = secnum
        if floortype == FT_LOWERFLOOR
          @fl_direction[k] = -1
          @fl_speed[k] = FLOORSPEED
          @fl_dest[k] = find_highest_floor_surrounding(secnum)
        elsif floortype == FT_LOWERFLOORTOLOWEST
          @fl_direction[k] = -1
          @fl_speed[k] = FLOORSPEED
          @fl_dest[k] = find_lowest_floor_surrounding(secnum)
        elsif floortype == FT_TURBOLOWER
          @fl_direction[k] = -1
          @fl_speed[k] = FLOORSPEED * 4
          @fl_dest[k] = find_highest_floor_surrounding(secnum)
          if @fl_dest[k] != lv.sector_floorheight[secnum]
            @fl_dest[k] = i32(@fl_dest[k] + 8 * FRACUNIT)
          end
        elsif floortype == FT_RAISEFLOOR
          @fl_direction[k] = 1
          @fl_speed[k] = FLOORSPEED
          @fl_dest[k] = find_lowest_ceiling_surrounding(secnum)
          if @fl_dest[k] > lv.sector_ceilingheight[secnum]
            @fl_dest[k] = lv.sector_ceilingheight[secnum]
          end
        elsif floortype == FT_RAISEFLOORTONEAREST
          @fl_direction[k] = 1
          @fl_speed[k] = FLOORSPEED
          @fl_dest[k] = find_next_highest_floor(secnum, lv.sector_floorheight[secnum])
        else
          raise LevelError, "EV_DoFloor: type #{floortype} not implemented"
        end
      end
      rtn
    end

    def t_move_ceiling(_k)
      raise LevelError, "T_MoveCeiling not implemented"
    end

    # --------------------------------------------------------------- teleports

    MT_TELEPORTMAN = 41
    MT_TFOG = 39

    def ev_teleport(line, side, thing)
      lv = @level
      return false if (@mobj_flags[thing] & Info::MF_MISSILE) != 0
      return false if side == 1
      tag = lv.line_tagno[line]
      i = 0
      while i < lv.num_sectors
        if lv.sector_tagno[i] == tag
          t = @th_next[0]
          while t != 0
            if @th_func[t] == TH_MOBJ
              m = @th_data[t]
              if @mobj_type[m] == MT_TELEPORTMAN && @mobj_sector[m] == i
                oldx = @mobj_x[thing]
                oldy = @mobj_y[thing]
                oldz = @mobj_z[thing]
                return false unless teleport_move(thing, @mobj_x[m], @mobj_y[m])
                @mobj_z[thing] = @mobj_floorz[thing]
                @pl_viewz = i32(@mobj_z[thing] + @pl_viewheight) if @mobj_player[thing] >= 0
                spawn_mobj(oldx, oldy, oldz, MT_TFOG)
                an = @mobj_angle[m] >> ANGLETOFINESHIFT
                spawn_mobj(i32(@mobj_x[m] + 20 * @finesine[an + 2048]),
                           i32(@mobj_y[m] + 20 * @finesine[an]),
                           @mobj_z[thing], MT_TFOG)
                @mobj_reactiontime[thing] = 18 if @mobj_player[thing] >= 0
                @mobj_angle[thing] = @mobj_angle[m]
                @mobj_momx[thing] = 0
                @mobj_momy[thing] = 0
                @mobj_momz[thing] = 0
                return true
              end
            end
            t = @th_next[t]
          end
        end
        i += 1
      end
      false
    end

    # --------------------------------------------------- line specials (walk)

    # `P_CrossSpecialLine` (`p_spec.c`). Only what appears in E1M5 is implemented,
    # and the rest fail loudly.
    def cross_special_line(line, side, thing)
      lv = @level
      sp = lv.line_special[line]
      if @mobj_player[thing] < 0
        t = @mobj_type[thing]
        return if t == MT_ROCKET || t == MT_PLASMA || t == MT_BFG ||
                  t == MT_TROOPSHOT || t == MT_HEADSHOT || t == MT_BRUISERSHOT
        ok = sp == 39 || sp == 97 || sp == 125 || sp == 126 ||
             sp == 4 || sp == 10 || sp == 88
        return unless ok
      end
      case sp
      when 2                       # W1 Open Door
        ev_do_door(line, VLD_OPEN)
        lv.line_special[line] = 0
      when 22                      # W1 Raise floor to nearest and change
        ev_do_plat(line, PT_RAISETONEARESTANDCHANGE, 0)
        lv.line_special[line] = 0
      when 35                      # W1 Lights Very Dark (E054: E1M3)
        ev_light_turn_on(line, 35)
        lv.line_special[line] = 0
      when 88                      # WR Plat down-wait-up-stay
        ev_do_plat(line, PT_DOWNWAITUPSTAY, 0)
      when 90                      # WR Raise Door
        ev_do_door(line, VLD_NORMAL)
      when 91                      # WR Raise Floor
        ev_do_floor(line, FT_RAISEFLOOR)
      when 97                      # WR Teleport
        ev_teleport(line, side, thing)
      when 98                      # WR Lower Floor (turbo)
        ev_do_floor(line, FT_TURBOLOWER)
      else
        # A special **not** in vanilla's `P_CrossSpecialLine` switch does
        # nothing (manual door special 1 and the like do not fire when walked over).
        # So as not to mix "just not implemented" with "vanilla does nothing too",
        # **only the numbers vanilla handles** are listed, and hitting one of them fails.
        if WALK_SPECIALS.include?(sp)
          raise LevelError,
                "P_CrossSpecialLine: line #{line} special #{sp} not implemented"
        end
      end
    end

    # Every case in the switch of `p_spec.c:P_CrossSpecialLine`.
    # A number not here is a no-op in vanilla too.
    WALK_SPECIALS = [
      2, 3, 4, 5, 6, 8, 10, 12, 13, 16, 17, 19, 22, 25, 30, 35, 36, 37, 38,
      39, 40, 44, 52, 53, 54, 56, 57, 58, 59, 72, 73, 74, 75, 76, 77, 79, 80,
      81, 82, 83, 84, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98,
      100, 104, 105, 106, 107, 108, 109, 110, 119, 120, 121, 124, 125, 126,
      128, 129, 130, 141
    ].freeze
    # **120 and 141 were missing** (missed when the list was first copied by hand).
    # Taken again mechanically from the pinned build's `p_spec.c`, giving 72.
    # DEMO1-DEMO3 never walk over them, so behaviour does not change, but
    # the boundary between "vanilla does nothing too" and "not implemented" had shifted.

    # `P_UseSpecialLine` (`p_switch.c`). Only the specials that appear in E1M5 are
    # implemented, and the rest fail loudly.
    def use_special_line(thing, line, side)
      lv = @level
      return false if side != 0
      sp = lv.line_special[line]
      if @mobj_player[thing] < 0
        # Monsters can open only manual doors, and not secret ones.
        return false if (lv.line_flags[line] & 32) != 0
        return false unless sp == 1 || sp == 32 || sp == 33 || sp == 34
      end
      if sp == 1 || sp == 26 || sp == 27 || sp == 28 ||
         sp == 31 || sp == 32 || sp == 33 || sp == 34
        ev_vertical_door(line, thing)
        return true
      end
      # Switches (only those in E1M5; the rest fail)
      case sp
      when 11                       # S1 Exit level
        change_switch_texture(line, 0)
        @exit_requested = true
      when 20                       # S1 Raise Plat to nearest and change (E054: E1M3)
        change_switch_texture(line, 0) if ev_do_plat(line, PT_RAISETONEARESTANDCHANGE, 0)
      when 62                       # SR PlatDownWaitUpStay
        change_switch_texture(line, 1) if ev_do_plat(line, PT_DOWNWAITUPSTAY, 0)
      when 70                       # SR Turbo lower floor
        change_switch_texture(line, 1) if ev_do_floor(line, FT_TURBOLOWER)
      when 98                       # SR Turbo lower floor
        change_switch_texture(line, 1) if ev_do_floor(line, FT_TURBOLOWER)
      when 103                      # S1 Open Door
        change_switch_texture(line, 0) if ev_do_door(line, VLD_OPEN)
      else
        # A special **not** in vanilla's `P_UseSpecialLine` switch
        # **does nothing and returns true** (the same structure as `P_CrossSpecialLine`).
        # Indeed E1M3's DEMO2 **uses** a "WR Raise Door (90)" linedef:
        # 90 is a walk number, absent from the use switch, so vanilla does nothing.
        # So as not to mix "numbers vanilla does nothing for" with "numbers not implemented
        # yet", there is **a list of the numbers vanilla handles**, and an unimplemented
        # one among them fails.
        if USE_SPECIALS.include?(sp)
          raise LevelError, "P_UseSpecialLine: line #{line} special #{sp} not implemented"
        end
      end
      true
    end

    # Every case in the "do something" switch of `p_switch.c:P_UseSpecialLine`
    # (63, taken mechanically from the pinned doomgeneric `dcb7a8db`).
    # A number not here is a no-op in vanilla too.
    USE_SPECIALS = [
      1, 7, 9, 11, 14, 15, 18, 20, 21, 23, 26, 27, 28, 29, 31, 32, 33, 34,
      41, 42, 43, 45, 49, 50, 51, 55, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69,
      70, 71, 99, 101, 102, 103, 111, 112, 113, 114, 115, 116, 117, 118, 122,
      123, 127, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140
    ].freeze

    # ------------------------------------------------------------------ switches

    BUTTONTIME = 35
    # The 19 pairs of `p_switch.c:alphSwitchList` with episode <= 1 (= shareware).
    SWITCH_NAMES = [
      "SW1BRCOM", "SW2BRCOM", "SW1BRN1", "SW2BRN1", "SW1BRN2", "SW2BRN2",
      "SW1BRNGN", "SW2BRNGN", "SW1BROWN", "SW2BROWN", "SW1COMM", "SW2COMM",
      "SW1COMP", "SW2COMP", "SW1DIRT", "SW2DIRT", "SW1EXIT", "SW2EXIT",
      "SW1GRAY", "SW2GRAY", "SW1GRAY1", "SW2GRAY1", "SW1METAL", "SW2METAL",
      "SW1PIPE", "SW2PIPE", "SW1SLAD", "SW2SLAD", "SW1STARG", "SW2STARG",
      "SW1STON1", "SW2STON1", "SW1STON2", "SW2STON2", "SW1STONE", "SW2STONE",
      "SW1STRTN", "SW2STRTN"
    ].freeze

    def init_switch_list
      @switchlist = Array.new(SWITCH_NAMES.length, 0)
      i = 0
      while i < SWITCH_NAMES.length
        @switchlist[i] = @texnames.texture_num(SWITCH_NAMES[i])
        i += 1
      end
    end

    def start_button(line, where, texture, time)
      i = 0
      while i < MAXBUTTONS
        if @button_timer[i] == 0
          @button_line[i] = line
          @button_where[i] = where
          @button_texture[i] = texture
          @button_timer[i] = time
          return
        end
        i += 1
      end
      raise LevelError, "P_StartButton: no button slots left"
    end

    # `P_ChangeSwitchTexture`
    def change_switch_texture(line, use_again)
      lv = @level
      lv.line_special[line] = 0 if use_again == 0
      sd = lv.line_side0[line]
      textop = lv.side_toptexture[sd]
      texmid = lv.side_midtexture[sd]
      texbot = lv.side_bottomtexture[sd]
      i = 0
      n = @switchlist.length
      while i < n
        if @switchlist[i] == textop
          lv.side_toptexture[sd] = @switchlist[i ^ 1]
          start_button(line, 0, @switchlist[i], BUTTONTIME) if use_again != 0
          return
        elsif @switchlist[i] == texmid
          lv.side_midtexture[sd] = @switchlist[i ^ 1]
          start_button(line, 1, @switchlist[i], BUTTONTIME) if use_again != 0
          return
        elsif @switchlist[i] == texbot
          lv.side_bottomtexture[sd] = @switchlist[i ^ 1]
          start_button(line, 2, @switchlist[i], BUTTONTIME) if use_again != 0
          return
        end
        i += 1
      end
    end

    # `P_ShootSpecialLine` (`p_spec.c`). It handles only 3 numbers, 24 / 46 / 47;
    # vanilla does nothing for the others either.
    def shoot_special_line(thing, line)
      sp = @level.line_special[line]
      if @mobj_player[thing] < 0
        return unless sp == 46
      end
      if sp == 24 || sp == 46 || sp == 47
        raise LevelError,
              "P_ShootSpecialLine: line #{line} special #{sp} not implemented"
      end
    end

    # `P_RadiusAttack` + `PIT_RadiusAttack` (`p_map.c`). Barrel explosions and rockets.
    # `MAXRADIUS` is used not as fixed but as **32 in map units**
    # (`(damage+MAXRADIUS)<<FRACBITS`: vanilla's MAXRADIUS is already fixed, so this is
    # a bug that shifts <<16 twice, but **it matches the pinned build**).
    def radius_attack(spot, source, damage)
      lv = @level
      dist = (damage + 32) << 16
      yh = (i32(@mobj_y[spot] + dist) - lv.bmaporgy) >> MAPBLOCKSHIFT
      yl = (i32(@mobj_y[spot] - dist) - lv.bmaporgy) >> MAPBLOCKSHIFT
      xh = (i32(@mobj_x[spot] + dist) - lv.bmaporgx) >> MAPBLOCKSHIFT
      xl = (i32(@mobj_x[spot] - dist) - lv.bmaporgx) >> MAPBLOCKSHIFT
      @bombspot = spot
      @bombsource = source
      @bombdamage = damage
      y = yl
      while y <= yh
        x = xl
        while x <= xh
          block_things_iterator_radius(x, y)
          x += 1
        end
        y += 1
      end
    end

    def block_things_iterator_radius(x, y)
      lv = @level
      return if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      m = @blocklinks[y * lv.bmapwidth + x]
      while m >= 0
        nxt = @mobj_bnext[m]
        pit_radius_attack(m)
        m = nxt
      end
    end

    def pit_radius_attack(thing)
      return if (@mobj_flags[thing] & Info::MF_SHOOTABLE) == 0
      return if @mobj_type[thing] == MT_CYBORG || @mobj_type[thing] == MT_SPIDER
      dx = abs_i(i32(@mobj_x[thing] - @mobj_x[@bombspot]))
      dy = abs_i(i32(@mobj_y[thing] - @mobj_y[@bombspot]))
      dist = dx > dy ? dx : dy
      dist = i32(dist - @mobj_radius[thing]) >> 16
      dist = 0 if dist < 0
      return if dist >= @bombdamage
      if check_sight(thing, @bombspot)
        damage_mobj(thing, @bombspot, @bombsource, @bombdamage - dist)
      end
    end
  end
end
