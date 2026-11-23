# doom/lib/doom/things.rb
#
# Makes mobjs from the THINGS lump (`P_SpawnMapThing` / `P_SpawnMobj` / `P_SpawnPlayer` in
# `p_mobj.c`, and **only the sector links** of `P_SetThingPosition` in `p_maputl.c`).
#
# Drawing needs mobjs for one reason: **`R_AddSprites` makes sprites in the link order of
# `sector->thinglist`**, so that order decides the order vissprites are made = the
# stability of the sort = the final drawing order.
#
# **Not one line of game logic is brought in.** No thinkers, no blockmap, no collision.
# `P_Random` is not touched either: `P_SpawnMobj` uses random numbers for `lastlook` and
# `tics`, but neither shows in the drawing (`sprite` / `frame` come straight from `spawnstate`).
# This is a note for when the number of `P_Random` calls starts being counted.
#
# `thinglist` inserts at the head, so **the order per sector is the reverse of the spawn order**.
# Here mobjs are pushed onto arrays in spawn order, and the per-sector links are made at the
# end in reverse (the linked list is not kept as ivar pointers).

require_relative "errors"
require_relative "bytes"
require_relative "info"

module Doom
  class Things
    MTF_EASY = 1
    MTF_NORMAL = 2
    MTF_HARD = 4
    MTF_AMBUSH = 8
    MTF_NOTSINGLE = 16

    attr_reader :count
    attr_reader :mobj_x, :mobj_y, :mobj_z, :mobj_angle, :mobj_type,
                :mobj_sprite, :mobj_frame, :mobj_flags, :mobj_radius,
                :mobj_height, :mobj_sector, :mobj_subsector
    # The thinglist per sector. `sector_head[s]` is the first mobj and `next[i]` the next (-1 ends it).
    attr_reader :sector_head, :thing_next
    attr_reader :player_mobj

    def initialize(wad, level, skill)
      data = wad.bytes(wad.map_lump(level.mapname, "THINGS"))
      n = data.bytesize / 10

      @doomednum = Info.mobj_doomednum
      @spawnstate = Info.mobj_spawnstate
      @info_radius = Info.mobj_radius
      @info_height = Info.mobj_height
      @info_flags = Info.mobj_flags
      @state_sprite = Info.state_sprite
      @state_frame = Info.state_frame

      @count = 0
      @mobj_x = []
      @mobj_y = []
      @mobj_z = []
      @mobj_angle = []
      @mobj_type = []
      @mobj_sprite = []
      @mobj_frame = []
      @mobj_flags = []
      @mobj_radius = []
      @mobj_height = []
      @mobj_sector = []
      @mobj_subsector = []
      @player_mobj = -1

      # `gameskill != sk_baby/sk_nightmare` -> bit = 1 << (skill-1)
      if skill == 0
        bit = 1
      elsif skill == 4
        bit = 4
      else
        bit = 1 << (skill - 1)
      end

      i = 0
      while i < n
        o = i * 10
        x = Bytes.i16(data, o)
        y = Bytes.i16(data, o + 2)
        angdeg = Bytes.i16(data, o + 4)
        type = Bytes.i16(data, o + 6)
        options = Bytes.i16(data, o + 8)
        spawn_map_thing(level, x, y, angdeg, type, options, bit)
        i += 1
      end

      build_sector_lists(level)
    end

    private

    def spawn_map_thing(level, x, y, angdeg, type, options, bit)
      return if type == 11          # deathmatch start
      return if type <= 0
      if type <= 4
        # single player: only playeringame[0] is true, so only type 1 makes a mobj.
        # **The last wins**: if the same type appears again the earlier player mobj is dropped
        # (vanilla's `P_SpawnPlayer` keeps the old mobj, but `players[0].mo` is
        # overwritten. E1M1 has one player 1 start, so no difference shows).
        return unless type == 1
        spawn_mobj(level, x << 16, y << 16, Info::ONFLOORZ, Info::MT_PLAYER, angdeg)
        @player_mobj = @count - 1
        return
      end
      return if (options & MTF_NOTSINGLE) != 0
      return if (options & bit) == 0

      t = 0
      t += 1 while t < @doomednum.length && @doomednum[t] != type
      raise LevelError, "unknown thing type #{type} at (#{x}, #{y})" if t == @doomednum.length

      z = (@info_flags[t] & Info::MF_SPAWNCEILING) != 0 ? Info::ONCEILINGZ : Info::ONFLOORZ
      spawn_mobj(level, x << 16, y << 16, z, t, angdeg)
      if (options & MTF_AMBUSH) != 0
        @mobj_flags[@count - 1] = @mobj_flags[@count - 1] | Info::MF_AMBUSH
      end
    end

    # Only the part of `P_SpawnMobj` that affects drawing. No thinker, no health, no reactiontime.
    def spawn_mobj(level, x, y, z, type, angdeg)
      st = @spawnstate[type]
      ss = level.point_in_subsector(x, y)
      sec = level.ss_sector[ss]
      floorz = level.sector_floorheight[sec]
      ceilingz = level.sector_ceilingheight[sec]
      h = @info_height[type]
      if z == Info::ONFLOORZ
        mz = floorz
      elsif z == Info::ONCEILINGZ
        mz = ceilingz - h
      else
        mz = z
      end
      i = @count
      @mobj_x[i] = x
      @mobj_y[i] = y
      @mobj_z[i] = mz
      @mobj_angle[i] = 0x20000000 * (angdeg / 45) & 0xffffffff
      @mobj_type[i] = type
      @mobj_sprite[i] = @state_sprite[st]
      @mobj_frame[i] = @state_frame[st]
      @mobj_flags[i] = @info_flags[type]
      @mobj_radius[i] = @info_radius[type]
      @mobj_height[i] = h
      @mobj_sector[i] = sec
      @mobj_subsector[i] = ss
      @count = i + 1
    end

    # `P_SetThingPosition`'s sector links insert at the head, so they are the reverse of the spawn order.
    # An `MF_NOSECTOR` mobj is not linked.
    def build_sector_lists(level)
      n = level.num_sectors
      @sector_head = Array.new(n, -1)
      @thing_next = Array.new(@count, -1)
      i = 0
      while i < @count
        if (@mobj_flags[i] & Info::MF_NOSECTOR) == 0
          s = @mobj_sector[i]
          @thing_next[i] = @sector_head[s]
          @sector_head[s] = i
        end
        i += 1
      end
    end
  end
end
