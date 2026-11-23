# doom/lib/doom/palette.rb
#
# PLAYPAL (14 palettes x 256 colours x RGB) and COLORMAP (34 rows x 256).
#
# **The palette has no effect on the frame buffer.** 8-bit index plane -> RGB happens
# only at the last stage (writing PPM or showing on real hardware). The differential oracle
# compares indices as they are, so the palette is a tool for a person to see whether "it is plausible as a picture".
#
# Row 0 of COLORMAP is **not the identity** (7 of the 256 do not map to themselves), so the
# optimization "skip the colormap at full brightness" changes the output. **It is not done.**

require_relative "errors"
require_relative "bytes"

module Doom
  # A 34-row x 256-byte "index -> index" mapping.
  class Colormap
    ROW_SIZE = 256
    NUM_ROWS = 34

    attr_reader :rows

    def initialize(bytes)
      if bytes.bytesize % ROW_SIZE != 0
        raise PaletteError, "COLORMAP size #{bytes.bytesize} is not a multiple of #{ROW_SIZE}"
      end
      @data = bytes
      @rows = bytes.bytesize / ROW_SIZE
      raise PaletteError, "COLORMAP has no rows" if @rows == 0
    end

    def map(row, index)
      @data.getbyte(row * ROW_SIZE + index)
    end

    # The value through brightness 0 (the brightest). Note that it is not the identity.
    def brightest(index)
      @data.getbyte(index)
    end

    def identity_row0?
      i = 0
      while i < ROW_SIZE
        return false if @data.getbyte(i) != i
        i += 1
      end
      true
    end
  end

  # RGB lookup through one of the 14 palettes.
  class Palette
    COLORS = 256
    PAL_SIZE = COLORS * 3

    attr_reader :count, :selected

    # The brightness table. **Using it while nil is the default**: like DOOM's `dc_colormap`,
    # it passes through when none is applied.
    # (This ivar is initialized to `nil`, assigned only from outside through `attr_accessor`,
    #  and read by a bare truth test `if @colormap`: exactly the form an earlier compiler
    #  defect folded wrongly. Since that was fixed it works correctly.
    #  No convention to work around that defect is kept.)
    attr_accessor :colormap

    # The brightness step (0 = the brightest, 31 = the darkest). Meaningful only with a colormap.
    attr_accessor :light

    def initialize(bytes)
      if bytes.bytesize % PAL_SIZE != 0
        raise PaletteError, "PLAYPAL size #{bytes.bytesize} is not a multiple of #{PAL_SIZE}"
      end
      @data = bytes
      @count = bytes.bytesize / PAL_SIZE
      raise PaletteError, "PLAYPAL has no palettes" if @count == 0
      @selected = 0
      @colormap = nil
      @light = 0
    end

    def select(n)
      raise PaletteError, "palette #{n} out of range (npals=#{@count})" if n < 0 || n >= @count
      @selected = n
    end

    def r(index)
      @data.getbyte(@selected * PAL_SIZE + resolve(index) * 3)
    end

    def g(index)
      @data.getbyte(@selected * PAL_SIZE + resolve(index) * 3 + 1)
    end

    def b(index)
      @data.getbyte(@selected * PAL_SIZE + resolve(index) * 3 + 2)
    end

    private

    def resolve(index)
      i = index
      i = @colormap.map(@light, index) if @colormap
      i
    end
  end
end
