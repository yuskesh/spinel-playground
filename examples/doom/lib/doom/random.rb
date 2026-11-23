# doom/lib/doom/random.rb
#
# `m_random.c`'s random numbers. **All of DOOM's determinism rests here.**
#
# The table is a fixed 256-byte table and cannot be generated (one of the 6 embedded tables
# in the port's conventions; the drawing stages did not need it, so it was embedded with the tic simulation).
#
#   `P_Random`  advances `prndindex`. **All of game play** (AI / damage /
#               hit tests / item drops / flickering lights). Demo playback's determinism is this
#   `M_Random`  advances `rndindex`. Asynchronous (menus / sound pitch /
#               intermission effects / **the status bar face** / **the melt wipe**)
#
# `M_ClearRandom` is called by `G_InitNew` and **resets both to 0 at the start of a level**.
# So the first `P_Random` always returns `rndtable[1] = 8` (not `rndtable[0]`).
#
# **The evaluation order of `P_Random() - P_Random()`** (a point once left "unverified"):
# disassembling the pinned doomgeneric `dcb7a8db` built with `-Os` on macOS arm64 and
# counting, **all 12 places are left to right** (the form `sub w8, w<first>, w0`).
# That is, **the call executed first is the minuend**, the same as Ruby's evaluation
# order. So `p_random - p_random` may be written plainly.
# But this is **"a fact of this build"**; whether vanilla on x86 had the same order
# has not been checked.
#
# The call sequence itself is the staged oracle's layer L5. `@seq` / `@log_*` are
# the hooks for checking it line by line against the reference implementation's `rand.tsv`.

module Doom
  class Random
    RNDTABLE = "\x00\x08\x6d\xdc\xde\xf1\x95\x6b\x4b\xf8\xfe\x8c\x10\x42\x4a\x15\xd3\x2f\x50\xf2\x9a\x1b\xcd\x80\xa1\x59\x4d\x24\x5f\x6e\x55\x30\xd4\x8c\xd3\xf9\x16\x4f\xc8\x32\x1c\xbc\x34\x8c\xca\x78\x44\x91\x3e\x46\xb8\xbe\x5b\xc5\x98\xe0\x95\x68\x19\xb2\xfc\xb6\xca\xb6\x8d\xc5\x04\x51\xb5\xf2\x91\x2a\x27\xe3\x9c\xc6\xe1\xc1\xdb\x5d\x7a\xaf\xf9\x00\xaf\x8f\x46\xef\x2e\xf6\xa3\x35\xa3\x6d\xa8\x87\x02\xeb\x19\x5c\x14\x91\x8a\x4d\x45\xa6\x4e\xb0\xad\xd4\xa6\x71\x5e\xa1\x29\x32\xef\x31\x6f\xa4\x46\x3c\x02\x25\xab\x4b\x88\x9c\x0b\x38\x2a\x92\x8a\xe5\x49\x92\x4d\x3d\x62\xc4\x87\x6a\x3f\xc5\xc3\x56\x60\xcb\x71\x65\xaa\xf7\xb5\x71\x50\xfa\x6c\x07\xff\xed\x81\xe2\x4f\x6b\x70\xa6\x67\xf1\x18\xdf\xef\x78\xc6\x3a\x3c\x52\x80\x03\xb8\x42\x8f\xe0\x91\xe0\x51\xce\xa3\x2d\x3f\x5a\xa8\x72\x3b\x21\x9f\x5f\x1c\x8b\x7b\x62\x7d\xc4\x0f\x46\xc2\xfd\x36\x0e\x6d\xe2\x47\x11\xa1\x5d\xba\x57\xf4\x8a\x14\x34\x7b\xfb\x1a\x24\x11\x2e\x34\xe7\xe8\x4c\x1f\xdd\x54\x25\xd8\xa5\xd4\x6a\xc5\xf2\x62\x2b\x27\xaf\xfe\x91\xbe\x54\x76\xde\xbb\x88\x78\xa3\xec\xf9".freeze

    attr_reader :prndindex, :rndindex, :pcount, :mcount

    def initialize
      @prndindex = 0
      @rndindex = 0
      @pcount = 0
      @mcount = 0
      @trace = false
      @log_tic = []
      @log_before = []
      @log_after = []
      @log_value = []
      @log_site = []
      @log_n = 0
      @tic = 0
    end

    # Enables recording (for the differential oracle; off by default, with zero allocation).
    def trace!(cap)
      @trace = true
      @log_tic = Array.new(cap, 0)
      @log_before = Array.new(cap, 0)
      @log_after = Array.new(cap, 0)
      @log_value = Array.new(cap, 0)
      @log_site = Array.new(cap, 0)
      @log_n = 0
    end

    def tic=(t)
      @tic = t
    end

    def log_n
      @log_n
    end

    def log_tic(i)
      @log_tic[i]
    end

    def log_before(i)
      @log_before[i]
    end

    def log_after(i)
      @log_after[i]
    end

    def log_value(i)
      @log_value[i]
    end

    def log_site(i)
      @log_site[i]
    end

    # `P_Random`. site is the call site's number (a SITE_* constant).
    # site is unused when tracing is off.
    def p_random(site)
      before = @prndindex
      i = (before + 1) & 0xff
      @prndindex = i
      v = RNDTABLE.getbyte(i)
      @pcount += 1
      if @trace && @log_n < @log_tic.length
        n = @log_n
        @log_tic[n] = @tic
        @log_before[n] = before
        @log_after[n] = i
        @log_value[n] = v
        @log_site[n] = site
        @log_n = n + 1
      end
      v
    end

    def m_random
      i = (@rndindex + 1) & 0xff
      @rndindex = i
      @mcount += 1
      RNDTABLE.getbyte(i)
    end

    def clear
      @prndindex = 0
      @rndindex = 0
    end
  end
end
