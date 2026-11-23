# doom/lib/doom/sprites.rb
#
# The index of sprite lumps (`R_InitSpriteDefs` / `R_InitSpriteLumps` in `r_things.c`).
# Following the predecessor's research notes on the specification.
#
# The lumps between `S_START`..`S_END` in the WAD are `NNNNFR` (6 characters) or
# `NNNNFRFR` (8 characters): `NNNN` is the sprite name, `F` the frame counting from 'A', and
# `R` the rotation '0'..'8'. `R == 0` is "the same picture from every direction";
# 1..8 are 8 directions. The 8-character form assigns the same lump to **2 rotations, mirrored**.
#
# The output is 3 SoA arrays:
#
#   frame_rotate[sprite][frame]        0 = a single picture / 1 = 8 directions
#   frame_lump[sprite][frame][rot]     the spritelump number (relative to firstspritelump)
#   frame_flip[sprite][frame][rot]     0/1
#
# Ruby does not build 3 levels of nesting; they are kept as **one Array with frame numbers
# flattened to a running number**. `sprite_framebase[s] + frame` is the running number, and
# `lump` and `flip` add `* 8 + rot`.
#
# `spritewidth` / `spriteoffset` / `spritetopoffset` are fixed_t values taken from the
# patch header, used as they are by `R_ProjectSprite`.

require_relative "errors"
require_relative "bytes"

module Doom
  class Sprites
    FRACBITS = 16

    attr_reader :numsprites, :firstspritelump, :numspritelumps

    def initialize(wad, sprnames)
      @wad = wad
      @firstspritelump = wad.num_for_name("S_START") + 1
      lastspritelump = wad.num_for_name("S_END") - 1
      @numspritelumps = lastspritelump - @firstspritelump + 1

      @lumppos = Array.new(@numspritelumps, 0)
      # A masked column that reads past the end of its lump looks up
      # `Wad#zone_window`, so **the lump number and its end** are kept too.
      @lumpnum = Array.new(@numspritelumps, 0)
      @lumpend = Array.new(@numspritelumps, 0)
      @spritewidth = Array.new(@numspritelumps, 0)
      @spriteoffset = Array.new(@numspritelumps, 0)
      @spritetopoffset = Array.new(@numspritelumps, 0)
      data = wad.data
      i = 0
      while i < @numspritelumps
        l = wad.lump(@firstspritelump + i)
        @lumppos[i] = l.pos
        @lumpnum[i] = @firstspritelump + i
        @lumpend[i] = l.pos + l.size
        @spritewidth[i] = Bytes.i16(data, l.pos) << FRACBITS
        @spriteoffset[i] = Bytes.i16(data, l.pos + 4) << FRACBITS
        @spritetopoffset[i] = Bytes.i16(data, l.pos + 6) << FRACBITS
        i += 1
      end

      @numsprites = sprnames.length
      @numframes = Array.new(@numsprites, 0)
      @framebase = Array.new(@numsprites, 0)
      @rotate = []
      @lump = []
      @flip = []
      init_sprite_defs(sprnames)
    end

    # The patch lump's absolute offset in the WAD (`R_DrawVisSprite` walks the posts directly).
    def lump_pos(l)
      @lumppos[l]
    end

    def lump_num(l)
      @lumpnum[l]
    end

    def lump_end(l)
      @lumpend[l]
    end

    def spritewidth(l)
      @spritewidth[l]
    end

    def spriteoffset(l)
      @spriteoffset[l]
    end

    def spritetopoffset(l)
      @spritetopoffset[l]
    end

    def numframes(s)
      @numframes[s]
    end

    def frame_rotate(s, f)
      @rotate[@framebase[s] + f]
    end

    def frame_lump(s, f, rot)
      @lump[(@framebase[s] + f) * 8 + rot]
    end

    def frame_flip(s, f, rot)
      @flip[(@framebase[s] + f) * 8 + rot]
    end

    private

    # `R_InitSpriteDefs`. Vanilla collects into a working array of 29 frames x 8 rotations and
    # then packs it. The same shape here (the working array is allocated once per sprite).
    def init_sprite_defs(sprnames)
      maxframe_rot = Array.new(29 * 8, -1)
      maxframe_flip = Array.new(29 * 8, 0)
      maxframe_rotate = Array.new(29, -1)

      s = 0
      while s < @numsprites
        name = sprnames[s]
        i = 0
        while i < 29
          maxframe_rotate[i] = -1
          j = 0
          while j < 8
            maxframe_rot[i * 8 + j] = -1
            maxframe_flip[i * 8 + j] = 0
            j += 1
          end
          i += 1
        end
        maxframe = -1

        l = 0
        while l < @numspritelumps
          ln = @wad.lump(@firstspritelump + l).name
          if ln.bytesize >= 6 && ln.byteslice(0, 4) == name
            frame = ln.getbyte(4) - 65        # 'A'
            rotation = ln.getbyte(5) - 48     # '0'
            maxframe = install_sprite_lump(maxframe_rot, maxframe_flip, maxframe_rotate,
                                           maxframe, l, frame, rotation, 0, name)
            if ln.bytesize >= 8
              frame = ln.getbyte(6) - 65
              rotation = ln.getbyte(7) - 48
              maxframe = install_sprite_lump(maxframe_rot, maxframe_flip, maxframe_rotate,
                                             maxframe, l, frame, rotation, 1, name)
            end
          end
          l += 1
        end

        maxframe += 1
        @framebase[s] = @rotate.length
        @numframes[s] = maxframe
        f = 0
        while f < maxframe
          case maxframe_rotate[f]
          when -1
            raise LevelError, "sprite #{name}: frame #{f} is missing"
          when 0
            # A single picture. Only rotation 0 needs to be filled.
            @rotate << 0
          else
            # 8 directions. All must be filled.
            r = 0
            while r < 8
              if maxframe_rot[f * 8 + r] == -1
                raise LevelError, "sprite #{name}: frame #{f} rotation #{r} is missing"
              end
              r += 1
            end
            @rotate << 1
          end
          r = 0
          while r < 8
            @lump << maxframe_rot[f * 8 + r]
            @flip << maxframe_flip[f * 8 + r]
            r += 1
          end
          f += 1
        end
        s += 1
      end
    end

    # `R_InstallSpriteLump`
    def install_sprite_lump(rot, flip, rotate, maxframe, lump, frame, rotation, flipped, name)
      if frame < 0 || frame >= 29 || rotation < 0 || rotation > 8
        raise LevelError, "sprite #{name}: bad frame/rotation #{frame}/#{rotation}"
      end
      maxframe = frame if frame > maxframe
      if rotation == 0
        if rotate[frame] == 1
          raise LevelError, "sprite #{name} frame #{frame}: rotations mixed with a single picture"
        end
        rotate[frame] = 0
        r = 0
        while r < 8
          rot[frame * 8 + r] = lump
          flip[frame * 8 + r] = flipped
          r += 1
        end
        return maxframe
      end
      if rotate[frame] == 0
        raise LevelError, "sprite #{name} frame #{frame}: single picture mixed with rotations"
      end
      rotate[frame] = 1
      r = rotation - 1
      if rot[frame * 8 + r] != -1
        raise LevelError, "sprite #{name} frame #{frame} rotation #{rotation}: duplicate lump"
      end
      rot[frame * 8 + r] = lump
      flip[frame * 8 + r] = flipped
      maxframe
    end
  end
end
