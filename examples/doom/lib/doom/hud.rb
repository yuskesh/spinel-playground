# doom/lib/doom/hud.rb
#
# The message line at the top of the screen (only the `w_message` route of `hu_stuff.c` + `hu_lib.c`).
#
# **This is not a renderer**, but it writes straight into `I_VideoBuffer`, so it affects the
# frame hash. It was the cause of the split at DEMO1's **tic 60**:
# the moment the player picks up armour, "Picked up the armor." appears in the top 7 lines.
# The reference implementation's visplanes, drawsegs and vissprites all matched this port's
# exactly, yet 785 pixels differed.
#
# Only `HU_Ticker`'s message display and `HUlib_drawTextLine` are implemented:
#
#   - the font is the 63 patches `STCFN033`..`STCFN095` (index = `c - '!'`)
#   - from `x = 0`, `y = 0`. A space or out-of-range character is `x += 4`; otherwise draw the
#     patch and `x += width`. Stop at `x + w > 320`
#   - shown for `HU_MSGTIMEOUT = 4*TICRATE = 140` tics
#
# Chat (`w_chat`) and the automap title (`w_title`) are not drawn in single player /
# outside the automap, so they are not kept.

require_relative "errors"
require_relative "bytes"

module Doom
  class Hud
    HU_FONTSTART = 33          # '!'
    HU_FONTSIZE = 63
    HU_MSGTIMEOUT = 140

    # Takes `scale` (s) and the real screen's size.
    # **The layout stays in 320x200 space** (vanilla's `x + w > 320` cut-off is kept
    # as it is); only when writing out is one pixel stretched to s x s.
    # At s = 1 the inner loops run once each, and not one bit differs from the
    # pixels fixed earlier.
    def initialize(wad, screenwidth, screenheight, scale)
      raise WadError, "hud scale #{scale} must be >= 1" if scale < 1
      @sw = screenwidth
      @sh = screenheight
      @scale = scale
      @wad = wad
      @data = wad.data
      @font_lump = Array.new(HU_FONTSIZE, -1)
      i = 0
      while i < HU_FONTSIZE
        n = HU_FONTSTART + i
        name = "STCFN" + (n < 100 ? "0" : "") + n.to_s
        l = wad.index_of(name)
        raise WadError, "hud font lump #{name} not found" if l < 0
        @font_lump[i] = l
        i += 1
      end
      # Messages are kept **by number**, and the strings are laid out in one Array at start-up.
      # With `@message = <a literal>` and a call to `@message.bytesize`, Spinel fails at run
      # time with `undefined method 'bytesize' for an instance of String`
      # (no minimal reproduction was made). As an Array element it gets a type.
      @texts = MESSAGES
      @message = 0
      @message_on = false
      @message_counter = 0
    end

    # The strings of `d_englsh.h`. The numbers are 1:1 with `Doom::Game`'s `MSG_*`.
    MESSAGES = [
      "",
      "Picked up the armor.",
      "Picked up the MegaArmor!",
      "Picked up a health bonus.",
      "Picked up an armor bonus.",
      "Picked up a stimpack.",
      "Picked up a medikit that you REALLY need!",
      "Picked up a medikit.",
      "Supercharge!",
      "MegaSphere!",
      "Picked up a blue keycard.",
      "Picked up a yellow keycard.",
      "Picked up a red keycard.",
      "Picked up a blue skull key.",
      "Picked up a yellow skull key.",
      "Picked up a red skull key.",
      "Invulnerability!",
      "Berserk!",
      "Partial Invisibility",
      "Radiation Shielding Suit",
      "Computer Area Map",
      "Light Amplification Visor",
      "Picked up a clip.",
      "Picked up a box of bullets.",
      "Picked up a rocket.",
      "Picked up a box of rockets.",
      "Picked up an energy cell.",
      "Picked up an energy cell pack.",
      "Picked up 4 shotgun shells.",
      "Picked up a box of shotgun shells.",
      "Picked up a backpack full of ammo!",
      "You got the chaingun!",
      "A chainsaw!  Find some meat!",
      "You got the rocket launcher!",
      "You got the shotgun!",
      "You need a blue key to open this door",
      "You need a yellow key to open this door",
      "You need a red key to open this door",
      "You need a blue key to activate this object",
      "You need a yellow key to activate this object",
      "You need a red key to activate this object"
    ].freeze

    def message_on
      @message_on
    end

    def message
      @message
    end

    # `HU_Ticker`. `msg` is the message number (0 = no message this tic).
    def ticker(msg)
      if @message_counter != 0
        @message_counter -= 1
        if @message_counter == 0
          @message_on = false
        end
      end
      if msg != 0
        @message = msg
        @message_on = true
        @message_counter = HU_MSGTIMEOUT
      end
    end

    # `HUlib_drawTextLine` (`x = 0`, `y = 0`, no cursor).
    def draw(screen)
      return unless @message_on
      text = @texts[@message]
      x = 0
      i = 0
      n = text.bytesize
      while i < n
        c = text.getbyte(i)
        i += 1
        c -= 32 if c >= 97 && c <= 122      # toupper
        if c != 32 && c >= HU_FONTSTART && c <= 95
          lump = @font_lump[c - HU_FONTSTART]
          w = Bytes.i16(@data, @wad.lump(lump).pos)
          break if x + w > 320
          draw_patch(screen, x, 0, lump)
          x += w
        else
          x += 4
          break if x >= 320
        end
      end
    end

    private

    # `V_DrawPatch` (no clipping, written straight into `screens[0]`).
    def draw_patch(dest, x, y, lumpnum)
      l = @wad.lump(lumpnum)
      base = l.pos
      w = Bytes.i16(@data, base)
      h = Bytes.i16(@data, base + 2)
      xoff = Bytes.i16(@data, base + 4)
      yoff = Bytes.i16(@data, base + 6)
      dx = x - xoff
      dy = y - yoff
      col = 0
      while col < w
        p = base + Bytes.i32(@data, base + 8 + col * 4)
        loop do
          td = @data.getbyte(p)
          break if td == 0xff
          len = @data.getbyte(p + 1)
          src = p + 3
          k = 0
          while k < len
            yy = dy + td + k
            if yy >= 0 && yy < 200
              v = @data.getbyte(src + k)
              s = @scale
              ry = 0
              while ry < s
                o = (yy * s + ry) * @sw + (dx + col) * s
                rx = 0
                while rx < s
                  dest.setbyte(o + rx, v)
                  rx += 1
                end
                ry += 1
              end
            end
            k += 1
          end
          p += len + 4
        end
        col += 1
      end
    end
  end
end
