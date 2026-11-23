# doom/lib/doom/demo.rb
#
# Reading `.lmp` demos (`G_DoPlayDemo` / `G_ReadDemoTiccmd` in `g_game.c`).
# Following the predecessor's research notes on the specification.
#
# **A 13-byte header** (version 109 = DOOM 1.9):
#   0 version / 1 skill / 2 episode / 3 map / 4 deathmatch / 5 respawn /
#   6 fast / 7 nomonsters / 8 consoleplayer / 9..12 playeringame[4]
#
# **4 bytes per tic**: forwardmove(i8) / sidemove(i8) / angleturn(u8) / buttons(u8).
# It ends when `DEMOMARKER = 0x80` comes in `forwardmove`'s place.
#
# There are 2 traps:
#
#   1. `angleturn` is quantized to 8 bits and is `<< 8` on reading.
#      The result 0..65280 is assigned to `ticcmd_t.angleturn` (**a `short`, signed**), so
#      0x8000 and above **become negative**. `v -= 0x10000 if v >= 0x8000` is needed.
#   2. `forwardmove` / `sidemove` are `signed char`.
#
# Measured (shareware DOOM1.WAD): DEMO1 = 20 118 B / **E1M5** / skill 2 / 5 026 tics.
# **A map the drawing stages never drew** (they all used E1M1).

require_relative "errors"
require_relative "bytes"

module Doom
  class Demo
    DEMOMARKER = 0x80
    HEADER = 13

    attr_reader :version, :skill, :episode, :map, :deathmatch, :respawnparm,
                :fastparm, :nomonsters, :consoleplayer, :numtics
    attr_reader :forwardmove, :sidemove, :angleturn, :buttons

    # **If `path` is not an empty string, it reads from that file instead of the WAD.**
    # The reference implementation's `-timedemo <path>` does `D_AddFile` on `<path>.lmp`
    # as a **single lump file**, so one `.lmp` recorded by `bin/record_demo.rb` can be fed
    # to both this port and the reference implementation: that is the
    # record -> play-on-both oracle.
    #
    # Not a convenience constructor with defaults (a port convention): **both callers
    # always pass both arguments explicitly**.
    def initialize(wad, lumpname, path)
      if path == ""
        i = wad.index_of(lumpname)
        raise WadError, "demo lump not found: #{lumpname}" if i < 0
        data = wad.bytes(i)
      else
        data = File.binread(path)
      end
      raise WadError, "#{lumpname}: #{data.bytesize} bytes is too short" if data.bytesize < HEADER + 1

      @version = data.getbyte(0)
      # Vanilla's `G_DoPlayDemo` accepts 106..109. This port accepts only 109 (1.9), which
      # the pinned reference implementation handles, and fails on anything else.
      raise WadError, "#{lumpname}: demo version #{@version} is not 109 (DOOM 1.9)" if @version != 109
      @skill = data.getbyte(1)
      @episode = data.getbyte(2)
      @map = data.getbyte(3)
      @deathmatch = data.getbyte(4)
      @respawnparm = data.getbyte(5)
      @fastparm = data.getbyte(6)
      @nomonsters = data.getbyte(7)
      @consoleplayer = data.getbyte(8)
      # playeringame[4]: this port accepts single player only.
      if data.getbyte(9) != 1 || data.getbyte(10) != 0 ||
         data.getbyte(11) != 0 || data.getbyte(12) != 0
        raise WadError, "#{lumpname}: only single player demos are supported"
      end
      raise WadError, "#{lumpname}: deathmatch demos are not supported" if @deathmatch != 0

      # Expands the whole tic sequence first (no allocation in the frame loop).
      cap = (data.bytesize - HEADER) / 4
      @forwardmove = Array.new(cap, 0)
      @sidemove = Array.new(cap, 0)
      @angleturn = Array.new(cap, 0)
      @buttons = Array.new(cap, 0)
      n = 0
      o = HEADER
      while o + 3 < data.bytesize
        f = data.getbyte(o)
        break if f == DEMOMARKER
        @forwardmove[n] = f >= 0x80 ? f - 0x100 : f
        s = data.getbyte(o + 1)
        @sidemove[n] = s >= 0x80 ? s - 0x100 : s
        a = data.getbyte(o + 2) << 8
        @angleturn[n] = a >= 0x8000 ? a - 0x10000 : a
        @buttons[n] = data.getbyte(o + 3)
        n += 1
        o += 4
      end
      if o >= data.bytesize || data.getbyte(o) != DEMOMARKER
        raise WadError, "#{lumpname}: no DEMOMARKER (0x80) at offset #{o}"
      end
      @numtics = n
    end

    def mapname
      "E#{@episode}M#{@map}"
    end
  end
end
