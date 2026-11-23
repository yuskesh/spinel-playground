# doom/lib/doom/record.rb
#
# **Writing** `.lmp` (`G_BeginRecording` / `G_WriteDemoTiccmd` /
# `G_CheckDemoStatus` in `g_game.c`).
#
# The reverse of the reading side (`demo.rb`), but **with it the differential oracle gets
# one step stronger**:
#
#   1. run an interactive (or synthetic-input) session and record a `.lmp`
#   2. have **this port** play the same `.lmp`              -> frame hash sequence A
#   3. have **the reference implementation** play the same `.lmp` -> frame hash sequence B
#   4. if A == B, "**a demo we recorded ourselves makes the same world as the reference implementation**"
#
# DEMO1-3 were recorded by id, and their inputs are given constants.
# What is recorded here is **the input sequence this port's `G_BuildTiccmd` made**, so it
# shows sameness with the reference implementation down to "how the input is made".
#
# **`G_WriteDemoTiccmd` reads back what it has just written** (vanilla):
#
#     *demo_p++ = (cmd->angleturn+128)>>8;
#     ...
#     G_ReadDemoTiccmd (cmd);   // make SURE it is exactly the same
#
#   The angle is quantized to 8 bits, so **the live game being recorded must also run on
#   the quantized value**. Otherwise "the recorded demo" and "the play being recorded"
#   become different worlds. `TiccmdBuilder#quantize_angle!` is that one step.

require_relative "errors"
require_relative "bytes"

module Doom
  class DemoWriter
    VERSION = 109                # DOOM 1.9
    DEMOMARKER = 0x80
    HEADER = 13

    def initialize(skill, episode, map, maxtics)
      raise Error, "demo maxtics must be positive" if maxtics <= 0
      @buf = Bytes.buffer(HEADER + maxtics * 4 + 1, 0)
      @buf.setbyte(0, VERSION)
      @buf.setbyte(1, skill)
      @buf.setbyte(2, episode)
      @buf.setbyte(3, map)
      @buf.setbyte(4, 0)         # deathmatch
      @buf.setbyte(5, 0)         # respawnparm
      @buf.setbyte(6, 0)         # fastparm
      @buf.setbyte(7, 0)         # nomonsters
      @buf.setbyte(8, 0)         # consoleplayer
      @buf.setbyte(9, 1)         # playeringame[0]
      @buf.setbyte(10, 0)
      @buf.setbyte(11, 0)
      @buf.setbyte(12, 0)
      @n = 0
      @max = maxtics
    end

    def numtics
      @n
    end

    # `G_WriteDemoTiccmd`. `aturn_byte` is what `TiccmdBuilder#quantize_angle!` returned
    # (= the one byte to write). It requires **the caller to have quantized already**
    # so that the game advances on the quantized value.
    def write_tic(forwardmove, sidemove, aturn_byte, buttons)
      raise Error, "demo buffer full (#{@max} tics)" if @n >= @max
      o = HEADER + @n * 4
      @buf.setbyte(o, forwardmove & 0xff)
      @buf.setbyte(o + 1, sidemove & 0xff)
      @buf.setbyte(o + 2, aturn_byte & 0xff)
      @buf.setbyte(o + 3, buttons & 0xff)
      @n += 1
    end

    # The writing side of `G_CheckDemoStatus`.
    def save(path)
      @buf.setbyte(HEADER + @n * 4, DEMOMARKER)
      File.open(path, "wb") { |f| f.write(@buf.byteslice(0, HEADER + @n * 4 + 1)) }
    end
  end
end
