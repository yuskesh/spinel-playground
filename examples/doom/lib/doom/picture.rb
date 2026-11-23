# doom/lib/doom/picture.rb
#
# The decoder of the picture format (patch).
#
#   header    : width int16 / height int16 / leftoffset int16 / topoffset int16
#               columnofs int32[width]   (byte offsets relative to the lump's start)
#   post      : topdelta u8 (0xFF = end of column) / length u8 / pad u8 /
#               pixels[length] / pad u8      -> the next post is at +length+4
#
# **Transparency is "not writing".** DOOM has no alpha and no colour key. Nothing is written
# in the gaps between posts, so a background marker filled beforehand (255 by default) stays.
# The reference side (doomgeneric's `V_DrawPatch`) means the same: it draws onto a plane
# painted 255 beforehand and then reads it out (`doomgeneric_dump.c`).
#
# **How allocation is done** (the recommended form):
#   - the lump is not expanded into post structs or Arrays. `getbyte` on the WAD's String in place.
#   - the output plane is a String allocated once at the start. No array or string per post.
#
# **The accepted subset** (only the forms vanilla actually reads):
#   - tall patches (DeePsea's accumulated topdelta) are **not implemented**. Vanilla does not
#     accumulate, and the shareware IWAD has none (measured: across all 968 picture lumps /
#     61 593 posts, 0 non-monotonic topdeltas, the largest topdelta 150, the tallest 200).
#   - an out-of-range `columnofs`, a post past the lump's end, a post past the height are
#     **all refused with `Doom::PictureError`**. Nothing is cut short quietly.

require_relative "errors"
require_relative "bytes"

module Doom
  class Picture
    # The default marker for transparent pixels. DOOM's palette has no "transparent", so
    # this is a value only for differential comparison (matching the reference side's DG_PATCH_BG).
    TRANSPARENT = 255

    # The largest dimensions this port accepts. Vanilla sets no limit, but this is the
    # guard that stops "reading on through a broken lump as a picture".
    MAX_DIM = 4096

    HEADER_SIZE = 8

    attr_reader :width, :height, :leftoffset, :topoffset,
                :plane, :posts, :pixels, :background

    # `source` is the whole WAD's String; `off`/`size` are the lump's place and length in it.
    # (It reads without making a byteslice, so no allocation of one lump is needed.)
    def initialize(source, off, size, background)
      @background = background
      parse_header(source, off, size)
      @plane = Bytes.buffer(@width * @height, background)
      @posts = 0
      @pixels = 0
      decode(source, off, size)
    end

    # Straight from a WAD lump number. **The background marker is always explicit**:
    # adding a convenience constructor with defaults makes a route no program calls,
    # which gets no type and breaks the generated C (a port convention).
    def self.from_wad(wad, lumpnum, background)
      l = wad.lump(lumpnum)
      new(wad.data, l.pos, l.size, background)
    end

    def at(x, y)
      @plane.getbyte(y * @width + x)
    end

    def opaque_count
      n = 0
      i = 0
      total = @width * @height
      while i < total
        n += 1 if @plane.getbyte(i) != @background
        i += 1
      end
      n
    end

    def fnv1a64_hex
      Bytes.fnv1a64_hex(@plane)
    end

    private

    def parse_header(source, off, size)
      if size < HEADER_SIZE
        raise PictureError, "lump too small for a patch header: #{size} bytes (need #{HEADER_SIZE})"
      end
      @width = Bytes.i16(source, off)
      @height = Bytes.i16(source, off + 2)
      @leftoffset = Bytes.i16(source, off + 4)
      @topoffset = Bytes.i16(source, off + 6)
      if @width <= 0 || @height <= 0 || @width > MAX_DIM || @height > MAX_DIM
        raise PictureError, "bad patch dimensions #{@width}x#{@height}"
      end
      need = HEADER_SIZE + 4 * @width
      if size < need
        raise PictureError, "lump too small for columnofs[#{@width}]: #{size} bytes (need #{need})"
      end
    end

    def decode(source, off, size)
      w = @width
      h = @height
      header_end = HEADER_SIZE + 4 * w
      col = 0
      while col < w
        colofs = Bytes.i32(source, off + HEADER_SIZE + col * 4)
        if colofs < header_end || colofs >= size
          raise PictureError,
                "columnofs[#{col}]=#{colofs} out of range [#{header_end},#{size})"
        end
        p = colofs
        terminated = false
        while p < size
          td = source.getbyte(off + p)
          if td == 0xff
            terminated = true
            break
          end
          raise PictureError, "post header truncated in column #{col}" if p + 3 > size
          len = source.getbyte(off + p + 1)
          if p + 3 + len > size
            raise PictureError, "post pixels run past the lump end in column #{col}"
          end
          if td + len > h
            raise PictureError,
                  "post (topdelta=#{td} length=#{len}) exceeds patch height #{h} in column #{col}"
          end
          src = off + p + 3      # 3 bytes after topdelta, length, unused
          row = td * w + col
          k = 0
          while k < len
            @plane.setbyte(row, source.getbyte(src + k))
            row += w
            k += 1
          end
          @posts += 1
          @pixels += len
          p += len + 4           # including the 1 byte of unused padding at the end
        end
        unless terminated
          raise PictureError, "column #{col} runs past the lump end (no 0xff terminator)"
        end
        col += 1
      end
    end
  end
end
