# doom/lib/doom/input.rb
#
# `g_game.c:G_BuildTiccmd`: the stage that **makes a ticcmd from the key state**.
#
# Before interactive play this port had only `G_ReadDemoTiccmd` (reading from a demo).
# Interactive play needs this. And since **a `.lmp` recorded with `-record` can be fed to
# the reference implementation**, it gives an oracle stronger than DEMO1-3:
# "a demo we recorded ourselves makes the same world as the reference".
#
# **It does not depend on SDL.** Input comes in the very shape of `gamekeydown[]`,
# "an array of 256 Integer 0/1". Whether SDL or a script fills it,
# `G_BuildTiccmd`'s side does not change by one line, so
# **the CRuby differential applies as it is** (`bin/record_demo.rb` runs under CRuby too).
#
# Not implemented (in vanilla but not needed for this port's interactive play):
# mouse / joystick / double click / `chatchar` / `consistancy` /
# `BT_SPECIAL` (pause, save). It is not that they **do nothing so that hitting them shows**;
# there is no input source for them, so they never fire.

require_relative "errors"

module Doom
  # DOOM's key codes (`doomdef.h`). The conversion from SDL scan codes is done by
  # `doomkey()` in `tools/sp_sdl_shim.c`.
  module Keys
    RIGHTARROW = 0xae
    LEFTARROW  = 0xac
    UPARROW    = 0xad
    DOWNARROW  = 0xaf
    RSHIFT     = 0xb6
    RCTRL      = 0x9d
    RALT       = 0xb8
    SPACE      = 32
    COMMA      = 44
    PERIOD     = 46

    # `m_misc.c`'s default bindings.
    RIGHT       = RIGHTARROW
    LEFT        = LEFTARROW
    UP          = UPARROW
    DOWN        = DOWNARROW
    STRAFELEFT  = COMMA
    STRAFERIGHT = PERIOD
    FIRE        = RCTRL
    USE         = SPACE
    STRAFE      = RALT
    SPEED       = RSHIFT

    # Name -> code (used by synthetic input scripts). It lists **only the keys
    # `TiccmdBuilder#build` actually reads**: there is no menu and no automap, so allowing
    # `esc` / `enter` / `tab` would make half-keys that "can be written but do nothing".
    #   (menus, automap and their keys are absent on purpose)
    NAMES = {
      "left" => LEFTARROW, "right" => RIGHTARROW,
      "up" => UPARROW, "down" => DOWNARROW,
      "forward" => UPARROW, "back" => DOWNARROW,
      "strafeleft" => COMMA, "straferight" => PERIOD,
      "fire" => RCTRL, "use" => SPACE, "strafe" => RALT, "speed" => RSHIFT,
      "w1" => 49, "w2" => 50, "w3" => 51, "w4" => 52,
      "w5" => 53, "w6" => 54, "w7" => 55
    }.freeze
  end

  # `gamekeydown[]` itself. 256 Integer 0/1.
  class KeyState
    def initialize
      @down = Array.new(256, 0)
    end

    def press(code)
      @down[code] = 1
    end

    def clear
      i = 0
      while i < 256
        @down[i] = 0
        i += 1
      end
    end

    def down
      @down
    end
  end

  # `G_BuildTiccmd`. **The mouse and joystick branches are dropped.**
  class TiccmdBuilder
    # `g_game.c`'s tables as they are.
    FORWARDMOVE = [0x19, 0x32].freeze
    SIDEMOVE    = [0x18, 0x28].freeze
    ANGLETURN   = [640, 1280, 320].freeze     # the third is "slow turn"
    SLOWTURNTICS = 6
    MAXPLMOVE = 0x32                          # = forwardmove[1]

    BT_ATTACK = 1
    BT_USE = 2
    BT_CHANGE = 4
    BT_WEAPONSHIFT = 3

    # Every key `build` actually reads. Interactive play reads only these from SDL
    # (`bin/doom.rb#read_keys`). **So that no key half works**,
    # there is only one table.
    WATCHED_KEYS = [
      Keys::RIGHT, Keys::LEFT, Keys::UP, Keys::DOWN,
      Keys::STRAFELEFT, Keys::STRAFERIGHT,
      Keys::FIRE, Keys::USE, Keys::STRAFE, Keys::SPEED,
      49, 50, 51, 52, 53, 54, 55, 56
    ].freeze

    attr_reader :forwardmove, :sidemove, :angleturn, :buttons

    def initialize
      @turnheld = 0
      @forwardmove = 0
      @sidemove = 0
      @angleturn = 0
      @buttons = 0
    end

    # `keydown` is `KeyState#down` (256 Integer 0/1).
    def build(keydown)
      # By the port's conventions, no bare `if` on an Integer that copies C's `boolean`.
      strafe = keydown[Keys::STRAFE] != 0
      speed = keydown[Keys::SPEED]            # 0/1 used directly as an index (as in vanilla)
      forward = 0
      side = 0
      turn = 0
      @buttons = 0

      # Two-step accelerating turn (`turnheld` carries over across frames).
      if keydown[Keys::RIGHT] != 0 || keydown[Keys::LEFT] != 0
        @turnheld += 1                        # ticdup = 1
      else
        @turnheld = 0
      end
      tspeed = @turnheld < SLOWTURNTICS ? 2 : speed

      if strafe
        side += SIDEMOVE[speed] if keydown[Keys::RIGHT] != 0
        side -= SIDEMOVE[speed] if keydown[Keys::LEFT] != 0
      else
        turn -= ANGLETURN[tspeed] if keydown[Keys::RIGHT] != 0
        turn += ANGLETURN[tspeed] if keydown[Keys::LEFT] != 0
      end

      forward += FORWARDMOVE[speed] if keydown[Keys::UP] != 0
      forward -= FORWARDMOVE[speed] if keydown[Keys::DOWN] != 0
      side += SIDEMOVE[speed] if keydown[Keys::STRAFERIGHT] != 0
      side -= SIDEMOVE[speed] if keydown[Keys::STRAFELEFT] != 0

      @buttons |= BT_ATTACK if keydown[Keys::FIRE] != 0
      @buttons |= BT_USE if keydown[Keys::USE] != 0

      # Weapon switch ('1'..'8'; **only the first one found**).
      i = 0
      while i < 8                             # NUMWEAPONS - 1
        if keydown[49 + i] != 0
          @buttons = @buttons | BT_CHANGE | (i << BT_WEAPONSHIFT)
          break
        end
        i += 1
      end

      forward = MAXPLMOVE if forward > MAXPLMOVE
      forward = -MAXPLMOVE if forward < -MAXPLMOVE
      side = MAXPLMOVE if side > MAXPLMOVE
      side = -MAXPLMOVE if side < -MAXPLMOVE

      @forwardmove = forward
      @sidemove = side
      # `ticcmd_t.angleturn` is a `short`.
      @angleturn = ((turn & 0xffff) ^ 0x8000) - 0x8000
    end

    # Brings itself in line with reading back the third byte `G_WriteDemoTiccmd` wrote
    # (`(angleturn+128)>>8` -> `<<8` -> short). **The live game being recorded runs on
    # the quantized value**, so the `.lmp` is exactly "what really happened".
    def quantize_angle!
      b = ((@angleturn + 128) >> 8) & 0xff
      v = b << 8
      @angleturn = v >= 0x8000 ? v - 0x10000 : v
      b
    end
  end

  # Synthetic input (instead of a person). One line = `<from> <to> <key>[,<key>...]` (tics inclusive at both ends).
  # From `#` to the end of the line is a comment. Blank lines are ignored.
  #
  #   0    104  up          # forward for 3 seconds
  #   105  139  right       # turn for 1 second
  #   140  174 fire,up      # fire while moving forward
  #
  # **An agent cannot give human input**, so the record -> play-on-both oracle
  # is driven by this.
  class KeyScript
    def initialize(path)
      @from = []
      @to = []
      @code = []
      @last = 0
      lines = File.read(path).split("\n")
      i = 0
      while i < lines.length
        raw = lines[i]
        i += 1
        cut = raw.index("#")
        text = cut ? raw[0, cut] : raw
        f = text.split(" ")
        next if f.length < 3
        a = f[0].to_i
        b = f[1].to_i
        names = f[2].split(",")
        j = 0
        while j < names.length
          n = names[j]
          unless Keys::NAMES.key?(n)
            raise Error, "key script: unknown key #{n.inspect} (line #{i})"
          end
          @from << a
          @to << b
          @code << Keys::NAMES[n]
          j += 1
        end
        @last = b if b > @last
      end
      raise Error, "key script #{path} is empty" if @code.empty?
    end

    # The script's last tic.
    def last_tic
      @last
    end

    # Reflects the key state at tic `t` into `ks`.
    def apply(ks, t)
      ks.clear
      i = 0
      while i < @code.length
        ks.press(@code[i]) if t >= @from[i] && t <= @to[i]
        i += 1
      end
    end
  end
end
