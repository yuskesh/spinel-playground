# doom/lib/doom/level.rb
#
# Loading level geometry (the P_Load* of `p_setup.c`).
#
# Kept **not as an array of structs but as "one Array per field" (SoA)**.
# For 3 reasons:
#
#   1. Making each `seg_t` one Ruby object would take 732 allocations, and every field
#      read would be a method call. With SoA it is one Array index,
#      `@seg_v1[i]`, and the elements fall to `TY_INT`.
#   2. Vanilla's pointers (`li->v1`, `ss->sector`, `ld->sidenum[]`) **all become
#      indexes**. `nil` is not mixed in (to avoid falling to poly), so
#      "none" is `-1` (`backsector` is the typical case).
#   3. The reference implementation's dumps are tables of indexes anyway, so the differential is plain to write.
#
# The lumps are looked up **relative to the map marker, not by name** (`P_SetupLevel`).
# BLOCKMAP / REJECT are not read at the level stage (not used for drawing:
# REJECT is line of sight and BLOCKMAP collision, both for the tic simulation).

require_relative "errors"
require_relative "bytes"
require_relative "fixed"
require_relative "texnames"

module Doom
  class Level
    # Heights and coordinates are fixed_t, angles BAM. All Arrays of Integer.
    attr_reader :vertex_x, :vertex_y
    attr_reader :sector_floorheight, :sector_ceilingheight, :sector_floorpic,
                :sector_ceilingpic, :sector_lightlevel, :sector_special, :sector_tagno
    attr_reader :side_textureoffset, :side_rowoffset, :side_toptexture,
                :side_bottomtexture, :side_midtexture, :side_sector
    attr_reader :line_v1, :line_v2, :line_dx, :line_dy, :line_flags, :line_special,
                :line_tagno, :line_slopetype, :line_bbox_top, :line_bbox_bottom,
                :line_bbox_left, :line_bbox_right, :line_side0, :line_side1,
                :line_frontsector, :line_backsector
    attr_reader :seg_v1, :seg_v2, :seg_angle, :seg_offset, :seg_linedef, :seg_side,
                :seg_sidedef, :seg_frontsector, :seg_backsector
    attr_reader :ss_numlines, :ss_firstline, :ss_sector
    attr_reader :node_x, :node_y, :node_dx, :node_dy, :node_bbox, :node_child0, :node_child1
    attr_reader :num_vertexes, :num_sectors, :num_sides, :num_lines, :num_segs,
                :num_subsectors, :num_nodes
    attr_reader :skyflatnum, :skytexture
    attr_reader :start_x, :start_y, :start_angle_deg
    attr_reader :mapname
    # ---- the surface added for the tic simulation ------------------------------------
    # The level and drawing stages only drew, so they did not read BLOCKMAP / REJECT /
    # P_GroupLines ("for the tic simulation", as the note at the top of level.rb says).
    # The tic simulation needs all 3:
    #   BLOCKMAP  collision (P_BlockLinesIterator / P_BlockThingsIterator)
    #   REJECT    trivial rejection for line of sight (P_CheckSight)
    #   a sector's line list  P_FindMinSurroundingLight / P_RecursiveSound /
    #                       moving sectors (P_ChangeSector)
    attr_reader :blockmap, :bmaporgx, :bmaporgy, :bmapwidth, :bmapheight,
                :blockmap_off
    attr_reader :reject
    attr_reader :sector_linecount, :sector_lineofs, :sector_lines
    attr_reader :sector_soundorg_x, :sector_soundorg_y
    attr_reader :sector_blockbox
    # Counters that prevent duplicates during a scan (vanilla's validcount is one global).
    attr_reader :line_validcount, :sector_validcount

    ML_TWOSIDED = 4

    ST_HORIZONTAL = 0
    ST_VERTICAL = 1
    ST_POSITIVE = 2
    ST_NEGATIVE = 3

    ANG45 = 0x20000000

    # A constant for writing 32-bit truncation inline.
    M32 = 0xffffffff
    SGN = 0x80000000

    # p_local.h
    MAPBLOCKSHIFT = 23        # FRACBITS + 7
    MAXRADIUS = 0x200000      # 32 * FRACUNIT

    def initialize(wad, mapname, episode)
      @wad = wad
      @mapname = mapname
      @tex = TextureNames.new(wad)
      raise LevelError, "map not found: #{mapname}" if wad.index_of(mapname) < 0

      # `P_SetupLevel`'s order as it is (the dependencies apply in this order).
      load_vertexes
      load_sectors
      load_sidedefs
      load_linedefs
      load_subsectors
      load_nodes
      load_segs
      group_subsector_sectors
      load_blockmap
      load_reject
      group_lines
      load_things

      @skyflatnum = @tex.flat_num("F_SKY1")
      @skytexture = @tex.texture_num(sky_name(episode))
    end

    # `R_PointInSubsector` (`r_main.c`). Needed to look up the floorz of a spawn point.
    def point_in_subsector(x, y)
      return 0 if @num_nodes == 0
      nodenum = @num_nodes - 1
      while (nodenum & 0x8000) == 0
        side = point_on_side(x, y, nodenum)
        nodenum = side == 0 ? @node_child0[nodenum] : @node_child1[nodenum]
      end
      nodenum & 0x7fff
    end

    # `R_PointOnSide`, copied as it is, including the sign-bit fast path.
    # C's `& 0x80000000` is the sign bit of a 32-bit fixed_t, so as long as the value fits
    # in 32 bits it is equivalent to `v < 0`. `dx`/`dy` are folded to 32 bits with `to_i32`
    # (a coordinate difference can exceed 2^32).
    def point_on_side(x, y, n)
      ndx = @node_dx[n]
      ndy = @node_dy[n]
      if ndx == 0
        return x <= @node_x[n] ? (ndy > 0 ? 1 : 0) : (ndy < 0 ? 1 : 0)
      end
      if ndy == 0
        return y <= @node_y[n] ? (ndx < 0 ? 1 : 0) : (ndx > 0 ? 1 : 0)
      end
      # The truncation is **written inline**.
      # Calling `Doom::Fixed.to_i32` / `.mul` would, together with the calls on the `Renderer`
      # side, close a cycle in the value flow, and type inference would widen both to untyped.
      dx = ((x - @node_x[n] & M32) ^ SGN) - SGN
      dy = ((y - @node_y[n] & M32) ^ SGN) - SGN
      neg = 0
      neg += 1 if ndy < 0
      neg += 1 if ndx < 0
      neg += 1 if dx < 0
      neg += 1 if dy < 0
      if neg.odd?
        return ((ndy < 0) != (dx < 0)) ? 1 : 0
      end
      left = (((ndy >> 16) * dx >> 16 & M32) ^ SGN) - SGN
      right = ((dy * (ndx >> 16) >> 16 & M32) ^ SGN) - SGN
      right < left ? 0 : 1
    end

    private

    def sky_name(episode)
      return "SKY2" if episode == 2
      return "SKY3" if episode == 3
      return "SKY4" if episode == 4
      "SKY1"
    end

    # Looked up relative to the marker lump; the record count is size / record length.
    # **A remainder fails**: vanilla truncates, but that only means quietly
    # accepting a broken WAD.
    def lump_for(sub, recsize)
      i = @wad.map_lump(@mapname, sub)
      raise LevelError, "#{@mapname}: missing #{sub}" if i < 0
      data = @wad.bytes(i)
      if data.bytesize % recsize != 0
        raise LevelError,
              "#{@mapname}/#{sub}: #{data.bytesize} bytes is not a multiple of #{recsize}"
      end
      data
    end

    def load_vertexes
      data = lump_for("VERTEXES", 4)
      @num_vertexes = data.bytesize / 4
      @vertex_x = Array.new(@num_vertexes, 0)
      @vertex_y = Array.new(@num_vertexes, 0)
      i = 0
      while i < @num_vertexes
        @vertex_x[i] = Bytes.i16(data, i * 4) << 16
        @vertex_y[i] = Bytes.i16(data, i * 4 + 2) << 16
        i += 1
      end
    end

    def load_sectors
      data = lump_for("SECTORS", 26)
      n = data.bytesize / 26
      @num_sectors = n
      @sector_floorheight = Array.new(n, 0)
      @sector_ceilingheight = Array.new(n, 0)
      @sector_floorpic = Array.new(n, 0)
      @sector_ceilingpic = Array.new(n, 0)
      @sector_lightlevel = Array.new(n, 0)
      @sector_special = Array.new(n, 0)
      @sector_tagno = Array.new(n, 0)
      i = 0
      while i < n
        o = i * 26
        @sector_floorheight[i] = Bytes.i16(data, o) << 16
        @sector_ceilingheight[i] = Bytes.i16(data, o + 2) << 16
        # Names are **folded to upper case before the lookup**. Vanilla's
        # `W_CheckNumForName` / `R_CheckTextureNumForName` are hashes through `strncasecmp`
        # and `toupper`, so **case is ignored**.
        # In the real doom1.wad, **E1M7's SIDEDEFS has one lower-case `step4`**, and an exact
        # match fails with `texture not found: "step4"`.
        @sector_floorpic[i] = @tex.flat_num(Bytes.name8_upper(data, o + 4))
        @sector_ceilingpic[i] = @tex.flat_num(Bytes.name8_upper(data, o + 12))
        @sector_lightlevel[i] = Bytes.i16(data, o + 20)
        @sector_special[i] = Bytes.i16(data, o + 22)
        @sector_tagno[i] = Bytes.i16(data, o + 24)
        i += 1
      end
    end

    def load_sidedefs
      data = lump_for("SIDEDEFS", 30)
      n = data.bytesize / 30
      @num_sides = n
      @side_textureoffset = Array.new(n, 0)
      @side_rowoffset = Array.new(n, 0)
      @side_toptexture = Array.new(n, 0)
      @side_bottomtexture = Array.new(n, 0)
      @side_midtexture = Array.new(n, 0)
      @side_sector = Array.new(n, 0)
      i = 0
      while i < n
        o = i * 30
        @side_textureoffset[i] = Bytes.i16(data, o) << 16
        @side_rowoffset[i] = Bytes.i16(data, o + 2) << 16
        # Folded to upper case before the lookup (for the same reason as SECTORS above).
        @side_toptexture[i] = @tex.texture_num(Bytes.name8_upper(data, o + 4))
        @side_bottomtexture[i] = @tex.texture_num(Bytes.name8_upper(data, o + 12))
        @side_midtexture[i] = @tex.texture_num(Bytes.name8_upper(data, o + 20))
        s = Bytes.i16(data, o + 28)
        raise LevelError, "sidedef #{i}: sector #{s} out of range" if s < 0 || s >= @num_sectors
        @side_sector[i] = s
        i += 1
      end
    end

    def load_linedefs
      data = lump_for("LINEDEFS", 14)
      n = data.bytesize / 14
      @num_lines = n
      @line_v1 = Array.new(n, 0)
      @line_v2 = Array.new(n, 0)
      @line_dx = Array.new(n, 0)
      @line_dy = Array.new(n, 0)
      @line_flags = Array.new(n, 0)
      @line_special = Array.new(n, 0)
      @line_tagno = Array.new(n, 0)
      @line_slopetype = Array.new(n, 0)
      @line_bbox_top = Array.new(n, 0)
      @line_bbox_bottom = Array.new(n, 0)
      @line_bbox_left = Array.new(n, 0)
      @line_bbox_right = Array.new(n, 0)
      @line_side0 = Array.new(n, 0)
      @line_side1 = Array.new(n, 0)
      @line_frontsector = Array.new(n, 0)
      @line_backsector = Array.new(n, 0)
      i = 0
      while i < n
        o = i * 14
        v1 = Bytes.i16(data, o)
        v2 = Bytes.i16(data, o + 2)
        if v1 < 0 || v1 >= @num_vertexes || v2 < 0 || v2 >= @num_vertexes
          raise LevelError, "linedef #{i}: vertex #{v1}/#{v2} out of range"
        end
        @line_v1[i] = v1
        @line_v2[i] = v2
        @line_flags[i] = Bytes.i16(data, o + 4)
        @line_special[i] = Bytes.i16(data, o + 6)
        @line_tagno[i] = Bytes.i16(data, o + 8)
        dx = @vertex_x[v2] - @vertex_x[v1]
        dy = @vertex_y[v2] - @vertex_y[v1]
        @line_dx[i] = dx
        @line_dy[i] = dy
        if dx == 0
          @line_slopetype[i] = ST_VERTICAL
        elsif dy == 0
          @line_slopetype[i] = ST_HORIZONTAL
        else
          @line_slopetype[i] = Fixed.div(dy, dx) > 0 ? ST_POSITIVE : ST_NEGATIVE
        end
        if @vertex_x[v1] < @vertex_x[v2]
          @line_bbox_left[i] = @vertex_x[v1]
          @line_bbox_right[i] = @vertex_x[v2]
        else
          @line_bbox_left[i] = @vertex_x[v2]
          @line_bbox_right[i] = @vertex_x[v1]
        end
        if @vertex_y[v1] < @vertex_y[v2]
          @line_bbox_bottom[i] = @vertex_y[v1]
          @line_bbox_top[i] = @vertex_y[v2]
        else
          @line_bbox_bottom[i] = @vertex_y[v2]
          @line_bbox_top[i] = @vertex_y[v1]
        end
        s0 = Bytes.i16(data, o + 10)
        s1 = Bytes.i16(data, o + 12)
        @line_side0[i] = s0
        @line_side1[i] = s1
        @line_frontsector[i] = s0 == -1 ? -1 : @side_sector[s0]
        @line_backsector[i] = s1 == -1 ? -1 : @side_sector[s1]
        i += 1
      end
    end

    def load_subsectors
      data = lump_for("SSECTORS", 4)
      n = data.bytesize / 4
      @num_subsectors = n
      @ss_numlines = Array.new(n, 0)
      @ss_firstline = Array.new(n, 0)
      @ss_sector = Array.new(n, 0)
      i = 0
      while i < n
        @ss_numlines[i] = Bytes.i16(data, i * 4)
        @ss_firstline[i] = Bytes.i16(data, i * 4 + 2)
        i += 1
      end
    end

    def load_nodes
      data = lump_for("NODES", 28)
      n = data.bytesize / 28
      @num_nodes = n
      @node_x = Array.new(n, 0)
      @node_y = Array.new(n, 0)
      @node_dx = Array.new(n, 0)
      @node_dy = Array.new(n, 0)
      # bbox is [node][child][BOXTOP..BOXRIGHT] flattened into 8n elements
      # (`node * 8 + child * 4 + which`). No 2-dimensional Array is made.
      @node_bbox = Array.new(n * 8, 0)
      @node_child0 = Array.new(n, 0)
      @node_child1 = Array.new(n, 0)
      i = 0
      while i < n
        o = i * 28
        @node_x[i] = Bytes.i16(data, o) << 16
        @node_y[i] = Bytes.i16(data, o + 2) << 16
        @node_dx[i] = Bytes.i16(data, o + 4) << 16
        @node_dy[i] = Bytes.i16(data, o + 6) << 16
        j = 0
        while j < 8
          @node_bbox[i * 8 + j] = Bytes.i16(data, o + 8 + j * 2) << 16
          j += 1
        end
        @node_child0[i] = Bytes.u16(data, o + 24)
        @node_child1[i] = Bytes.u16(data, o + 26)
        i += 1
      end
    end

    def load_segs
      data = lump_for("SEGS", 12)
      n = data.bytesize / 12
      @num_segs = n
      @seg_v1 = Array.new(n, 0)
      @seg_v2 = Array.new(n, 0)
      @seg_angle = Array.new(n, 0)
      @seg_offset = Array.new(n, 0)
      @seg_linedef = Array.new(n, 0)
      @seg_side = Array.new(n, 0)
      @seg_sidedef = Array.new(n, 0)
      @seg_frontsector = Array.new(n, 0)
      @seg_backsector = Array.new(n, 0)
      i = 0
      while i < n
        o = i * 12
        @seg_v1[i] = Bytes.i16(data, o)
        @seg_v2[i] = Bytes.i16(data, o + 2)
        # `li->angle = SHORT(ml->angle) << 16`: the top 16 bits of the BAM.
        # The int16 is read as signed and then folded to 32 bits (a negative angle is 2^32's complement).
        @seg_angle[i] = Fixed.bam(Bytes.i16(data, o + 4) << 16)
        ld = Bytes.i16(data, o + 6)
        raise LevelError, "seg #{i}: linedef #{ld} out of range" if ld < 0 || ld >= @num_lines
        @seg_linedef[i] = ld
        side = Bytes.i16(data, o + 8)
        @seg_side[i] = side
        @seg_offset[i] = Bytes.i16(data, o + 10) << 16
        sd = side == 0 ? @line_side0[ld] : @line_side1[ld]
        raise LevelError, "seg #{i}: sidedef #{sd} out of range" if sd < 0 || sd >= @num_sides
        @seg_sidedef[i] = sd
        @seg_frontsector[i] = @side_sector[sd]
        if (@line_flags[ld] & ML_TWOSIDED) != 0
          other = side == 0 ? @line_side1[ld] : @line_side0[ld]
          if other < 0 || other >= @num_sides
            # Vanilla's "glass hack": an out-of-range sidenum points at sector 0.
            # It does not exist in shareware's E1M1. If it did, it would not go on quietly.
            raise LevelError, "seg #{i}: two-sided linedef #{ld} has sidenum #{other}"
          end
          @seg_backsector[i] = @side_sector[other]
        else
          @seg_backsector[i] = -1
        end
        i += 1
      end
    end

    # `P_LoadBlockMap` (`p_setup.c`). The whole lump is an array of int16:
    # the first 4 words are the header, and the next w*h words each block's word offset.
    # **The offsets are `short` (signed) in vanilla**, but no shareware map
    # reaches 64 K words, so they agree with unsigned.
    # Here they are read signed, as vanilla does.
    def load_blockmap
      i = @wad.map_lump(@mapname, "BLOCKMAP")
      raise LevelError, "#{@mapname}: missing BLOCKMAP" if i < 0
      data = @wad.bytes(i)
      raise LevelError, "#{@mapname}/BLOCKMAP: odd size #{data.bytesize}" if data.bytesize.odd?
      n = data.bytesize / 2
      raise LevelError, "#{@mapname}/BLOCKMAP: too short (#{n} words)" if n < 4
      @bmaporgx = Bytes.i16(data, 0) << 16
      @bmaporgy = Bytes.i16(data, 2) << 16
      @bmapwidth = Bytes.i16(data, 4)
      @bmapheight = Bytes.i16(data, 6)
      if @bmapwidth <= 0 || @bmapheight <= 0 ||
         4 + @bmapwidth * @bmapheight > n
        raise LevelError,
              "#{@mapname}/BLOCKMAP: #{@bmapwidth}x#{@bmapheight} does not fit in #{n} words"
      end
      # The whole lump is kept as an array of words (an offset is a word number from the lump's start).
      @blockmap = Array.new(n, 0)
      j = 0
      while j < n
        @blockmap[j] = Bytes.i16(data, j * 2)
        j += 1
      end
      # block number -> the list's word offset
      @blockmap_off = Array.new(@bmapwidth * @bmapheight, 0)
      j = 0
      while j < @bmapwidth * @bmapheight
        @blockmap_off[j] = @blockmap[4 + j]
        j += 1
      end
    end

    # Like `P_LoadReject`. A bitmap of numsectors^2 bits.
    # Used only for `P_CheckSight`'s trivial rejection.
    def load_reject
      i = @wad.map_lump(@mapname, "REJECT")
      raise LevelError, "#{@mapname}: missing REJECT" if i < 0
      # Written as `@reject.bytesize` through the ivar, Spinel fails with
      # `undefined method 'bytesize' for an instance of String`.
      # Put in a local first and measured, it works.
      data = @wad.bytes(i)
      need = (@num_sectors * @num_sectors + 7) / 8
      if data.bytesize < need
        raise LevelError,
              "#{@mapname}/REJECT: #{data.bytesize} bytes, need #{need} for #{@num_sectors} sectors"
      end
      @reject = data
    end

    # `P_GroupLines` (`p_setup.c`). Each sector's linedef list, soundorg and blockbox.
    # **The list is in ascending linedef number** (vanilla packs it in 2 passes).
    # `P_RecursiveSound` and `P_FindMinSurroundingLight` depend on this order.
    #
    # No linked list: `sector_linecount[s]` lines are taken from `sector_lineofs[s]` in the
    # single array `sector_lines` (no 2-dimensional arrays).
    def group_lines
      @sector_linecount = Array.new(@num_sectors, 0)
      i = 0
      while i < @num_lines
        s0 = @line_frontsector[i]
        @sector_linecount[s0] += 1 if s0 >= 0
        s1 = @line_backsector[i]
        @sector_linecount[s1] += 1 if s1 >= 0 && s1 != s0
        i += 1
      end
      @sector_lineofs = Array.new(@num_sectors, 0)
      total = 0
      i = 0
      while i < @num_sectors
        @sector_lineofs[i] = total
        total += @sector_linecount[i]
        i += 1
      end
      @sector_lines = Array.new(total, 0)
      fill = Array.new(@num_sectors, 0)
      i = 0
      while i < @num_lines
        s0 = @line_frontsector[i]
        if s0 >= 0
          @sector_lines[@sector_lineofs[s0] + fill[s0]] = i
          fill[s0] += 1
        end
        s1 = @line_backsector[i]
        if s1 >= 0 && s1 != s0
          @sector_lines[@sector_lineofs[s1] + fill[s1]] = i
          fill[s1] += 1
        end
        i += 1
      end

      # bbox -> soundorg (the second half of `P_GroupLines`).
      @sector_soundorg_x = Array.new(@num_sectors, 0)
      @sector_soundorg_y = Array.new(@num_sectors, 0)
      @sector_blockbox = Array.new(@num_sectors * 4, 0)
      i = 0
      while i < @num_sectors
        top = -0x7fffffff
        bottom = 0x7fffffff
        left = 0x7fffffff
        right = -0x7fffffff
        k = 0
        c = @sector_linecount[i]
        o = @sector_lineofs[i]
        while k < c
          ld = @sector_lines[o + k]
          left = @line_bbox_left[ld] if @line_bbox_left[ld] < left
          right = @line_bbox_right[ld] if @line_bbox_right[ld] > right
          bottom = @line_bbox_bottom[ld] if @line_bbox_bottom[ld] < bottom
          top = @line_bbox_top[ld] if @line_bbox_top[ld] > top
          k += 1
        end
        # Vanilla does `(right+left)/2`, and C's `/` rounds **toward 0**.
        # The sum is folded to 32 bits before dividing.
        sx = (((right + left & M32) ^ SGN) - SGN)
        sy = (((top + bottom & M32) ^ SGN) - SGN)
        @sector_soundorg_x[i] = sx < 0 ? -((-sx) / 2) : sx / 2
        @sector_soundorg_y[i] = sy < 0 ? -((-sy) / 2) : sy / 2
        # blockbox is folded to block coordinates and clamped (`P_ChangeSector` uses it).
        b = (top - @bmaporgy + MAXRADIUS) >> MAPBLOCKSHIFT
        b = @bmapheight - 1 if b >= @bmapheight
        @sector_blockbox[i * 4] = b
        b = (bottom - @bmaporgy - MAXRADIUS) >> MAPBLOCKSHIFT
        b = 0 if b < 0
        @sector_blockbox[i * 4 + 1] = b
        b = (left - @bmaporgx - MAXRADIUS) >> MAPBLOCKSHIFT
        b = 0 if b < 0
        @sector_blockbox[i * 4 + 2] = b
        b = (right - @bmaporgx + MAXRADIUS) >> MAPBLOCKSHIFT
        b = @bmapwidth - 1 if b >= @bmapwidth
        @sector_blockbox[i * 4 + 3] = b
        i += 1
      end

      @line_validcount = Array.new(@num_lines, 0)
      @sector_validcount = Array.new(@num_sectors, 0)
    end

    # The end of `P_GroupLines`: `ss->sector = segs[ss->firstline].sidedef->sector`.
    def group_subsector_sectors
      i = 0
      while i < @num_subsectors
        f = @ss_firstline[i]
        raise LevelError, "subsector #{i}: firstline #{f} out of range" if f < 0 || f >= @num_segs
        @ss_sector[i] = @side_sector[@seg_sidedef[f]]
        i += 1
      end
    end

    # Takes player 1's spawn point from THINGS. `P_SpawnMapThing` calls `P_SpawnPlayer`
    # each time type <= 4, so **the last one wins**.
    # The 3 ivars are **always initialized before the loop**. Assigned only inside the
    # condition, their type becomes `Integer | nil` and attr_reader's return falls to poly.
    # Then the one poly in `viewx = lv.start_x << 16` reaches
    # `point_in_subsector` -> `point_on_side` -> **`Doom::Fixed.to_i32`**,
    # and Fixed does not specialize module functions per call site, so
    # **the whole renderer falls to the boxed poly route**.
    def load_things
      data = lump_for("THINGS", 10)
      n = data.bytesize / 10
      @start_x = 0
      @start_y = 0
      @start_angle_deg = 0
      found = false
      i = 0
      while i < n
        o = i * 10
        if Bytes.i16(data, o + 6) == 1
          @start_x = Bytes.i16(data, o)
          @start_y = Bytes.i16(data, o + 2)
          @start_angle_deg = Bytes.i16(data, o + 4)
          found = true
        end
        i += 1
      end
      raise LevelError, "#{@mapname}: no player 1 start" unless found
    end
  end
end
