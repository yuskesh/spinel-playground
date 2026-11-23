# doom/lib/doom/texnames.rb
#
# **Only the assignment** of texture numbers and flat numbers.
#
# The level stage composes no texture at all (that comes with drawing), but **it needs the numbers**:
#
#   - `P_LoadSideDefs` turns names into numbers and stores them in `side_t`. With different
#     numbers the geometry dump splits from the reference.
#   - whether a number is 0 (`"-"` = no texture) **changes the clip values** of
#     `R_RenderSegLoop` (if `toptexture` is 0, `ceilingclip = yl-1`; otherwise it is
#     the `mid` drawn). Even without composing, 0 or not-0 is needed.
#   - `skyflatnum` (= the flat number of `F_SKY1`) appears in the branches of `R_Subsector`
#     and `R_StoreWallRange`.
#
# `R_CheckTextureNumForName` is a hash table in vanilla, but **a number is defined as
# "the 0-based running number in the order of appearance in TEXTURE1 (+TEXTURE2)"**, not by
# the hash. Here a linear Hash lookup returns the same numbers.

require_relative "errors"
require_relative "bytes"

module Doom
  class TextureNames
    attr_reader :numtextures, :firstflat

    def initialize(wad)
      @tex = {}
      @numtextures = 0
      add_texture_lump(wad, "TEXTURE1")
      add_texture_lump(wad, "TEXTURE2") if wad.index_of("TEXTURE2") >= 0

      # `R_InitFlats`: firstflat = W_GetNumForName("F_START") + 1
      @firstflat = wad.num_for_name("F_START") + 1
      @wad = wad
    end

    # `R_TextureNumForName`. `"-"` is 0 (the reserved number for "no texture").
    # Fails if not found (like vanilla's `I_Error`).
    def texture_num(name)
      # **Do not call `bytesize` / `getbyte` on the argument.** It is a poly through which
      # both "a byteslice cut from the WAD" and "a frozen literal in the source" flow,
      # and Spinel's dynamic dispatch has no `String#bytesize`, so it fails **at run time**
      # with `undefined method 'bytesize' for an instance of
      # String`.
      # Written with Hash lookup and `==` only, it means the same.
      return @tex[name] if @tex.key?(name)
      return 0 if name == "-"          # the reserved number for "no texture"
      raise LevelError, "texture not found: #{name.inspect}"
    end

    # `R_CheckTextureNumForName`. -1 if absent (it does not fail).
    # Added for `P_InitPicAnims` (the animation definitions include texture names
    # from other episodes, so a way to return "absent" quietly is needed).
    def texture_num_or_none(name)
      return @tex[name] if @tex.key?(name)
      return 0 if name == "-"
      -1
    end

    # `R_FlatNumForName`: looks up the whole directory and subtracts firstflat
    # (not a search confined to the flat namespace; vanilla does it this way).
    def flat_num(name)
      i = @wad.index_of(name)
      raise LevelError, "flat not found: #{name.inspect}" if i < 0
      i - @firstflat
    end

    private

    # TEXTURE1/2 lump: int32 numtextures / int32 offsets[] /
    # the first 8 bytes of each maptexture_t are the name.
    def add_texture_lump(wad, lumpname)
      data = wad.bytes_by_name(lumpname)
      raise LevelError, "#{lumpname}: too small (#{data.bytesize} bytes)" if data.bytesize < 4
      n = Bytes.i32(data, 0)
      raise LevelError, "#{lumpname}: bad numtextures #{n}" if n < 0
      need = 4 + n * 4
      raise LevelError, "#{lumpname}: truncated directory (#{data.bytesize} < #{need})" if data.bytesize < need
      i = 0
      while i < n
        off = Bytes.i32(data, 4 + i * 4)
        if off < 0 || off + 8 > data.bytesize
          raise LevelError, "#{lumpname}: texture #{i} offset #{off} out of range [0,#{data.bytesize})"
        end
        # The table side is also kept **folded to upper case** (vanilla's `R_CheckTextureNumForName`
        # uses `strncasecmp`). All 125 in the real doom1.wad's TEXTURE1 are upper case, so
        # the numbers do not change, but it stays symmetric with the looking-up side (`level.rb`).
        name = Bytes.name8_upper(data, off)
        @tex[name] = @numtextures unless @tex.key?(name)
        @numtextures += 1
        i += 1
      end
    end
  end
end
