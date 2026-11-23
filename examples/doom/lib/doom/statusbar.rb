# doom/lib/doom/statusbar.rb
#
# The status bar (`ST_Drawer` in `st_stuff.c` / widget drawing in `st_lib.c`).
#
# The reference implementation's `ST_doRefresh` works in 2 steps:
#
#   1. `ST_refreshBackground` draws `STBAR` into `st_backing_screen` (320x32) and
#      transfers it to the screen's y=168..199 with `V_CopyRect`.
#   2. `ST_drawWidgets(refresh=true)` draws each widget. A number widget
#      **pastes the background again with `V_CopyRect` before drawing**.
#
# **That `V_CopyRect` can be left out in this port.** The source pasted again is
# `st_backing_screen` (= `STBAR` itself), the screen there holds only the `STBAR` placed in 1,
# and in the widgets' drawing order (ready -> ammo -> maxammo -> health -> armor -> armsbg -> arms ->
# faces -> keys -> frags) **no later widget's restored area overlaps an earlier widget's
# drawn area** (measured: ready x~17-44 / health 62-90 / armsbg 104-143 /
# arms 111-146 / faces 143-166 / armor 193-221 / ammo 279-288 / maxammo 305-314).
# That leaving it out is correct was checked by a gate (statusbar.bin, 10 240 pixels matching).
#
# **The `ST_Ticker` and incremental drawing with `V_CopyRect` were added later.**
# Before that, only "the state where no tic has run" was drawn
# (`st_notdeathmatch` is false, so `STARMS` does not show). Running DEMO1 in full,
#
#   - the face (`w_faces`) changes every tic with `st_randomnumber % 3`, pain, attacks and weapon pickups
#   - ammo, health and armour go down. **When digits drop, the old digits stay**, so
#     `STlib_drawNum`'s `V_CopyRect` (pasting the background again) is needed
#   - `STARMS` and the key icons appear
#
# so all of it is needed. The argument at the top that "`V_CopyRect` can be left out"
# **was right only for the single `refresh = true` frame**. In `ST_diffDraw` (the second frame on)
# the pasting itself makes the picture, and leaving it out leaves digits behind.
#
# `ST_doPaletteStuff` only calls `I_SetPalette` and **does not touch the 8-bit index plane**,
# so it is not kept (this port applies no palette).
# `HU_Erase` also does nothing with screenblocks 10, since `viewwindowx == 0`.

require_relative "errors"
require_relative "bytes"

module Doom
  class StatusBar
    SCREENWIDTH = 320
    SCREENHEIGHT = 200
    ST_HEIGHT = 32
    ST_Y = SCREENHEIGHT - ST_HEIGHT       # 168

    ST_AMMOX = 44
    ST_AMMOY = 171
    ST_AMMOWIDTH = 3
    ST_HEALTHX = 90
    ST_HEALTHY = 171
    ST_ARMORX = 221
    ST_ARMORY = 171
    ST_ARMSX = 111
    ST_ARMSY = 172
    ST_ARMSXSPACE = 12
    ST_ARMSYSPACE = 10
    ST_FACESX = 143
    ST_FACESY = 168
    ST_AMMO0X = 288
    ST_AMMO0Y = 173
    ST_AMMO1Y = 179
    ST_AMMO2Y = 191
    ST_AMMO3Y = 185
    ST_MAXAMMO0X = 314
    ST_MAXAMMO0Y = 173
    ST_MAXAMMO1Y = 179
    ST_MAXAMMO2Y = 191
    ST_MAXAMMO3Y = 185
    ST_ARMSBGX = 104
    ST_ARMSBGY = 168
    ST_KEY0X = 239
    ST_KEY0Y = 171
    ST_KEY1Y = 181
    ST_KEY2Y = 191

    # Faces (the ST_NUM* group of `st_stuff.c`)
    ST_NUMPAINFACES = 5
    ST_NUMSTRAIGHTFACES = 3
    ST_NUMTURNFACES = 2
    ST_NUMSPECIALFACES = 3
    ST_FACESTRIDE = ST_NUMSTRAIGHTFACES + ST_NUMTURNFACES + ST_NUMSPECIALFACES  # 8
    ST_NUMEXTRAFACES = 2
    ST_NUMFACES = ST_FACESTRIDE * ST_NUMPAINFACES + ST_NUMEXTRAFACES            # 42
    ST_TURNOFFSET = ST_NUMSTRAIGHTFACES                                          # 3
    ST_OUCHOFFSET = ST_TURNOFFSET + ST_NUMTURNFACES                              # 5
    ST_EVILGRINOFFSET = ST_OUCHOFFSET + 1                                        # 6
    ST_RAMPAGEOFFSET = ST_EVILGRINOFFSET + 1                                     # 7
    ST_GODFACE = ST_NUMPAINFACES * ST_FACESTRIDE                                 # 40
    ST_DEADFACE = ST_GODFACE + 1                                                 # 41
    ST_EVILGRINCOUNT = 70          # 2*TICRATE
    ST_STRAIGHTFACECOUNT = 17      # TICRATE/2
    ST_TURNCOUNT = 35              # 1*TICRATE
    ST_RAMPAGEDELAY = 70           # 2*TICRATE
    ST_MUCHPAIN = 20

    ANG45 = 0x20000000
    ANG180 = 0x80000000

    NUMWEAPONS = 9

    # The 3 states of `plyr->attacker` in `ST_updateFaceWidget`.
    ATTACKER_NONE = 0
    ATTACKER_SELF = 1
    ATTACKER_OTHER = 2

    def initialize(wad)
      @wad = wad
      @data = wad.data
      @backing = Bytes.buffer(SCREENWIDTH * ST_HEIGHT, 0)
      @sbar = wad.num_for_name("STBAR")
      @tallpercent = wad.num_for_name("STTPRCNT")
      @tallnum = Array.new(10, 0)
      @shortnum = Array.new(10, 0)
      i = 0
      while i < 10
        @tallnum[i] = wad.num_for_name("STTNUM#{i}")
        @shortnum[i] = wad.num_for_name("STYSNUM#{i}")
        i += 1
      end
      # `arms[i][0]` = grey STGNUM{i+2} / `arms[i][1]` = yellow shortnum[i+2]
      @armsgray = Array.new(6, 0)
      i = 0
      while i < 6
        @armsgray[i] = wad.num_for_name("STGNUM#{i + 2}")
        i += 1
      end
      # The 42 faces of `ST_loadGraphics`. Their order gives `st_faceindex` its meaning.
      @faces = Array.new(ST_NUMFACES, 0)
      f = 0
      i = 0
      while i < ST_NUMPAINFACES
        j = 0
        while j < ST_NUMSTRAIGHTFACES
          @faces[f] = wad.num_for_name("STFST#{i}#{j}")
          f += 1
          j += 1
        end
        @faces[f] = wad.num_for_name("STFTR#{i}0")     # facing right
        @faces[f + 1] = wad.num_for_name("STFTL#{i}0") # facing left
        @faces[f + 2] = wad.num_for_name("STFOUCH#{i}")
        @faces[f + 3] = wad.num_for_name("STFEVL#{i}")
        @faces[f + 4] = wad.num_for_name("STFKILL#{i}")
        f += 5
        i += 1
      end
      @faces[f] = wad.num_for_name("STFGOD0")
      @faces[f + 1] = wad.num_for_name("STFDEAD0")
      # The 6 keys and the arms background.
      @keys = Array.new(6, 0)
      i = 0
      while i < 6
        @keys[i] = wad.num_for_name("STKEYS#{i}")
        i += 1
      end
      @armsbg = wad.num_for_name("STARMS")
      @tallw = Bytes.i16(@data, wad.lump(@tallnum[0]).pos)
      @shortw = Bytes.i16(@data, wad.lump(@shortnum[0]).pos)

      # ---- the state of `ST_initData` + `ST_createWidgets` ----------------------
      @firsttime = true              # st_firsttime
      @faceindex = 0                 # st_faceindex
      @facecount = 0                 # st_facecount (file static = 0)
      @priority = 0                  # ST_updateFaceWidget's static
      @lastattackdown = -1           # likewise
      @paincalc = 0                  # ST_calcPainOffset's lastcalc
      @painhealth = -1               # likewise, oldhealth
      @oldhealth = -1                # st_oldhealth
      @notdeathmatch = false         # false until ST_Ticker runs
      # `ST_initData`'s `oldweaponsowned[] = plyr->weaponowned[]` is
      # copied in `start` (StatusBar holds no game state).
      @oldweaponsowned = Array.new(NUMWEAPONS, 0)
      @keyboxes = Array.new(3, -1)
      # The widgets' old values (`STlib_init*`). Number widgets are redrawn every time, so not kept.
      @old_arms = Array.new(6, -1)
      @old_face = -1
      @old_keybox = Array.new(3, -1)
      @old_armsbg = false
    end

    # `ST_Start` -> `ST_initData`. Called **at the start of a level and before drawing one standalone frame**.
    # It raises `st_firsttime` again, so the next `draw` is `ST_doRefresh`
    # (pasting `STBAR` again + all widgets).
    # `ST_updateFaceWidget`'s `priority` / `lastattackdown` and
    # `ST_calcPainOffset`'s `lastcalc` / `oldhealth` are **function statics**, so
    # `ST_initData` does not reset them. Neither does this.
    def start(weaponowned)
      @firsttime = true
      @faceindex = 0
      @oldhealth = -1
      @notdeathmatch = false
      i = 0
      while i < NUMWEAPONS
        @oldweaponsowned[i] = weaponowned[i]
        i += 1
      end
      i = 0
      while i < 3
        @keyboxes[i] = -1
        @old_keybox[i] = -1
        i += 1
      end
      i = 0
      while i < 6
        @old_arms[i] = -1
        i += 1
      end
      @old_face = -1
      @old_armsbg = false
    end

    # ------------------------------------------------------------------ ticker

    # `ST_calcPainOffset`. **It has 2 statics** (`lastcalc` / `oldhealth`).
    def calc_pain_offset(health)
      h = health > 100 ? 100 : health
      if h != @painhealth
        @paincalc = ST_FACESTRIDE * (((100 - h) * ST_NUMPAINFACES) / 101)
        @painhealth = h
      end
      @paincalc
    end

    # `ST_Ticker` + `ST_updateWidgets` + `ST_updateFaceWidget`.
    # The game state is passed as arguments (it does not depend on `Doom::Game`).
    # `attacker` is one of the 3 `ATTACKER_*` values, and `badguyangle` is
    # `R_PointToAngle2(mo.x, mo.y, attacker.x, attacker.y)`.
    def ticker(randomnumber, health, weaponowned, cards, damagecount,
               bonuscount, attackdown, invulnerability,
               attacker, badguyangle, playerangle)
      # The key widgets
      i = 0
      while i < 3
        @keyboxes[i] = cards[i] != 0 ? i : -1
        @keyboxes[i] = i + 3 if cards[i + 3] != 0
        i += 1
      end

      update_face(randomnumber, health, weaponowned, damagecount, bonuscount,
                  attackdown, invulnerability, attacker, badguyangle, playerangle)

      @notdeathmatch = true          # always true in single player
      @oldhealth = health            # st_oldhealth comes **last** in ST_Ticker
    end

    def update_face(randomnumber, health, weaponowned, damagecount, bonuscount,
                    attackdown, invulnerability, attacker, badguyangle, playerangle)
      if @priority < 10 && health == 0
        @priority = 9
        @faceindex = ST_DEADFACE
        @facecount = 1
      end

      if @priority < 9 && bonuscount != 0
        # An evil grin only at the moment a weapon is picked up. **`oldweaponsowned` is
        # updated as a side effect of the comparison** (copying vanilla's code as it is).
        doevilgrin = false
        i = 0
        while i < NUMWEAPONS
          if @oldweaponsowned[i] != weaponowned[i]
            doevilgrin = true
            @oldweaponsowned[i] = weaponowned[i]
          end
          i += 1
        end
        if doevilgrin
          @priority = 8
          @facecount = ST_EVILGRINCOUNT
          @faceindex = calc_pain_offset(health) + ST_EVILGRINOFFSET
        end
      end

      if @priority < 8 && damagecount != 0 && attacker == ATTACKER_OTHER
        @priority = 7
        if health - @oldhealth > ST_MUCHPAIN
          @facecount = ST_TURNCOUNT
          @faceindex = calc_pain_offset(health) + ST_OUCHOFFSET
        else
          if badguyangle > playerangle
            diffang = badguyangle - playerangle
            right = diffang > ANG180
          else
            diffang = playerangle - badguyangle
            right = diffang <= ANG180
          end
          @facecount = ST_TURNCOUNT
          @faceindex = calc_pain_offset(health)
          if diffang < ANG45
            @faceindex += ST_RAMPAGEOFFSET
          elsif right
            @faceindex += ST_TURNOFFSET
          else
            @faceindex += ST_TURNOFFSET + 1
          end
        end
      end

      if @priority < 7 && damagecount != 0
        if health - @oldhealth > ST_MUCHPAIN
          @priority = 7
          @facecount = ST_TURNCOUNT
          @faceindex = calc_pain_offset(health) + ST_OUCHOFFSET
        else
          @priority = 6
          @facecount = ST_TURNCOUNT
          @faceindex = calc_pain_offset(health) + ST_RAMPAGEOFFSET
        end
      end

      if @priority < 6
        # Holding fire. `lastattackdown` is **a function static**, and
        # `ST_initData` does not reset it.
        if attackdown != 0
          if @lastattackdown == -1
            @lastattackdown = ST_RAMPAGEDELAY
          else
            @lastattackdown -= 1
            if @lastattackdown == 0
              @priority = 5
              @faceindex = calc_pain_offset(health) + ST_RAMPAGEOFFSET
              @facecount = 1
              @lastattackdown = 1
            end
          end
        else
          @lastattackdown = -1
        end
      end

      if @priority < 5 && invulnerability != 0
        @priority = 4
        @faceindex = ST_GODFACE
        @facecount = 1
      end

      if @facecount == 0
        @faceindex = calc_pain_offset(health) + (randomnumber % 3)
        @facecount = ST_STRAIGHTFACECOUNT
        @priority = 0
      end
      @facecount -= 1
    end

    # What `ST_Drawer(fullscreen=false, refresh)` draws.
    # `refresh` follows from `st_firsttime`: **only the first frame is `ST_doRefresh`**
    # (pasting `STBAR` again and drawing every widget); from the second on it is `ST_diffDraw`.
    # The player's state is passed as arguments (no game logic brought in).
    def draw(screen, health, armorpoints, ammo, maxammo, weaponowned, readyweapon, ammokind)
      refresh = @firsttime
      if refresh
        @firsttime = false
        refresh_background(screen)
      end

      # ready weapon ammo (tall). For an `am_noammo` weapon it is 1994 = "n/a".
      ready = ammokind < 0 || ammokind >= 4 ? 1994 : ammo[ammokind]
      update_num(screen, ST_AMMOX, ST_AMMOY, ST_AMMOWIDTH, ready, @tallnum, @tallw)

      # ammo / maxammo (short)
      update_num(screen, ST_AMMO0X, ST_AMMO0Y, 3, ammo[0], @shortnum, @shortw)
      update_num(screen, ST_MAXAMMO0X, ST_MAXAMMO0Y, 3, maxammo[0], @shortnum, @shortw)
      update_num(screen, ST_AMMO0X, ST_AMMO1Y, 3, ammo[1], @shortnum, @shortw)
      update_num(screen, ST_MAXAMMO0X, ST_MAXAMMO1Y, 3, maxammo[1], @shortnum, @shortw)
      update_num(screen, ST_AMMO0X, ST_AMMO2Y, 3, ammo[2], @shortnum, @shortw)
      update_num(screen, ST_MAXAMMO0X, ST_MAXAMMO2Y, 3, maxammo[2], @shortnum, @shortw)
      update_num(screen, ST_AMMO0X, ST_AMMO3Y, 3, ammo[3], @shortnum, @shortw)
      update_num(screen, ST_MAXAMMO0X, ST_MAXAMMO3Y, 3, maxammo[3], @shortnum, @shortw)

      # health / armor are percent widgets: `%` is drawn only on refresh.
      draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, ST_HEALTHX, ST_HEALTHY, @tallpercent) if refresh
      update_num(screen, ST_HEALTHX, ST_HEALTHY, 3, health, @tallnum, @tallw)
      draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, ST_ARMORX, ST_ARMORY, @tallpercent) if refresh
      update_num(screen, ST_ARMORX, ST_ARMORY, 3, armorpoints, @tallnum, @tallw)

      # w_armsbg (`STlib_updateBinIcon`): drawn if true; if false **the background is pasted again**.
      if @old_armsbg != @notdeathmatch || refresh
        if @notdeathmatch
          draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, ST_ARMSBGX, ST_ARMSBGY, @armsbg)
        else
          copy_rect_from_backing(screen, @armsbg, ST_ARMSBGX, ST_ARMSBGY)
        end
        @old_armsbg = @notdeathmatch
      end

      # w_arms[i]: weapons held are yellow (shortnum[i+2]); weapons not held are grey.
      i = 0
      while i < 6
        v = weaponowned[i + 1] != 0 ? 1 : 0
        if @old_arms[i] != v || refresh
          x = ST_ARMSX + (i % 3) * ST_ARMSXSPACE
          y = ST_ARMSY + (i / 3) * ST_ARMSYSPACE
          copy_rect_from_backing(screen, arms_lump(i, @old_arms[i]), x, y) if @old_arms[i] != -1
          draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, x, y, arms_lump(i, v))
          @old_arms[i] = v
        end
        i += 1
      end

      # w_faces (`STlib_updateMultIcon`)
      if (@old_face != @faceindex || refresh) && @faceindex != -1
        copy_rect_from_backing(screen, @faces[@old_face], ST_FACESX, ST_FACESY) if @old_face != -1
        draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, ST_FACESX, ST_FACESY, @faces[@faceindex])
        @old_face = @faceindex
      end

      # w_keyboxes
      i = 0
      while i < 3
        v = @keyboxes[i]
        if (@old_keybox[i] != v || refresh) && v != -1
          y = i == 0 ? ST_KEY0Y : (i == 1 ? ST_KEY1Y : ST_KEY2Y)
          copy_rect_from_backing(screen, @keys[@old_keybox[i]], ST_KEY0X, y) if @old_keybox[i] != -1
          draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, ST_KEY0X, y, @keys[v])
          @old_keybox[i] = v
        end
        i += 1
      end

      # w_frags: `st_fragson` is true only in deathmatch.
    end

    private

    def arms_lump(i, owned)
      owned == 1 ? @shortnum[i + 2] : @armsgray[i]
    end

    # `ST_refreshBackground`: draws STBAR into the 320x32 back buffer and then transfers it.
    def refresh_background(screen)
      backing = @backing
      i = 0
      n = SCREENWIDTH * ST_HEIGHT
      while i < n
        backing.setbyte(i, 0)
        i += 1
      end
      draw_patch(@backing, SCREENWIDTH, ST_HEIGHT, 0, 0, @sbar)
      i = 0
      while i < n
        screen.setbyte(ST_Y * SCREENWIDTH + i, @backing.getbyte(i))
        i += 1
      end
    end

    # `V_CopyRect(x, y-ST_Y, st_backing_screen, w, h, x, y)`.
    # From the patch's top left (after subtracting `leftoffset`/`topoffset`), w x h is pasted
    # again from `st_backing_screen` (= `STBAR` itself).
    # **`st_backing_screen` is 320x32, but V_CopyRect's stride is
    # SCREENWIDTH (320)**: the widths are the same, so the index is plain to compute.
    def copy_rect_from_backing(screen, lumpnum, x, y)
      l = @wad.lump(lumpnum)
      p = l.pos
      w = Bytes.i16(@data, p)
      h = Bytes.i16(@data, p + 2)
      cx = x - Bytes.i16(@data, p + 4)
      cy = y - Bytes.i16(@data, p + 6)
      copy_rect(screen, cx, cy, w, h)
    end

    def copy_rect(screen, x, y, w, h)
      if x < 0 || x + w > SCREENWIDTH || y < ST_Y || y + h > SCREENHEIGHT
        raise LevelError,
              "V_CopyRect out of the status bar: (#{x},#{y}) #{w}x#{h}"
      end
      row = 0
      while row < h
        src = (y - ST_Y + row) * SCREENWIDTH + x
        dst = (y + row) * SCREENWIDTH + x
        k = 0
        while k < w
          screen.setbyte(dst + k, @backing.getbyte(src + k))
          k += 1
        end
        row += 1
      end
    end

    # `STlib_updateNum` -> `STlib_drawNum`. **The background is always pasted again before drawing**
    # (`V_CopyRect(x, n->y - ST_Y, st_backing_screen, w*numdigits, h, x, n->y)`).
    # This pasting was once left out, but **when digits drop the old digits stay**, so
    # it cannot be left out over the whole of DEMO1.
    def update_num(screen, nx, ny, numdigits, num, nums, w)
      raise LevelError, "STlib_drawNum: negative value #{num}" if num < 0 && num != 1994
      h = Bytes.i16(@data, @wad.lump(nums[0]).pos + 2)
      copy_rect(screen, nx - numdigits * w, ny, w * numdigits, h)
      return if num == 1994          # vanilla's "n/a"
      x = nx
      draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, x - w, ny, nums[0]) if num == 0
      d = numdigits
      v = num
      while v != 0 && d > 0
        d -= 1
        x -= w
        draw_patch(screen, SCREENWIDTH, SCREENHEIGHT, x, ny, nums[v % 10])
        v /= 10
      end
    end

    # `V_DrawPatch`. Walks the posts directly (not through Picture: no plane needs making).
    def draw_patch(dest, dw, dh, x, y, lumpnum)
      l = @wad.lump(lumpnum)
      p = l.pos
      w = Bytes.i16(@data, p)
      h = Bytes.i16(@data, p + 2)
      x -= Bytes.i16(@data, p + 4)
      y -= Bytes.i16(@data, p + 6)
      if x < 0 || x + w > dw || y < 0 || y + h > dh
        raise LevelError,
              "V_DrawPatch out of range: #{l.name} at (#{x},#{y}) #{w}x#{h} into #{dw}x#{dh}"
      end
      col = 0
      while col < w
        c = p + Bytes.i32(@data, p + 8 + col * 4)
        while true
          td = @data.getbyte(c)
          break if td == 0xff
          len = @data.getbyte(c + 1)
          src = c + 3
          o = (y + td) * dw + x + col
          k = 0
          while k < len
            dest.setbyte(o, @data.getbyte(src + k))
            o += dw
            k += 1
          end
          c += len + 4
        end
        col += 1
      end
    end
  end
end
