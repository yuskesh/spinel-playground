# doom/lib/doom/bytes.rb
#
# Little-endian reads from a byte string (String).
#
# **`unpack` is not used.** Measured, `unpack("C*")` uses 6 mallocs / 8 432 bytes per
# 256 bytes. `getbyte` returns an `mrb_int` directly, so it is unboxed from the
# start and allocates nothing.
# The WAD is 4 MB and picture decoding appears in the frame loop too, so this is
# written from the start in allocation-free words only.
#
# The conventions' `to_i32` is **not** here: the first stage uses no fixed point.
# `Doom::Fixed` is added as a separate file at the level stage.

module Doom
  module Bytes

    def self.u8(s, o)
      s.getbyte(o)
    end

    def self.u16(s, o)
      s.getbyte(o) | (s.getbyte(o + 1) << 8)
    end

    def self.i16(s, o)
      v = s.getbyte(o) | (s.getbyte(o + 1) << 8)
      v >= 0x8000 ? v - 0x10000 : v
    end

    def self.u32(s, o)
      s.getbyte(o) | (s.getbyte(o + 1) << 8) |
        (s.getbyte(o + 2) << 16) | (s.getbyte(o + 3) << 24)
    end

    def self.i32(s, o)
      v = s.getbyte(o) | (s.getbyte(o + 1) << 8) |
          (s.getbyte(o + 2) << 16) | (s.getbyte(o + 3) << 24)
      v >= 0x80000000 ? v - 0x100000000 : v
    end

    # An 8-byte lump name, cut at the first NUL (equivalent to `unpack1("Z8")`).
    # A name of exactly 8 characters has no NUL.
    def self.name8(s, o)
      n = 0
      n += 1 while n < 8 && s.getbyte(o + n) != 0
      s.byteslice(o, n)
    end

    # Returns an 8-byte lump name **folded to upper case**.
    # Vanilla's `W_CheckNumForName` looks up with `strncasecmp`, so matching lump names
    # ignores case. **The real doom1.wad's PNAMES needs this**: one of its 350 entries
    # (index 162) alone is the lower-case `w94_1`, and with an exact match `TEKWALL4`
    # cannot be composed and it fails.
    def self.name8_upper(s, o)
      n = 0
      n += 1 while n < 8 && s.getbyte(o + n) != 0
      b = buffer(n, 0)
      i = 0
      while i < n
        c = s.getbyte(o + i)
        c -= 32 if c >= 97 && c <= 122
        b.setbyte(i, c)
        i += 1
      end
      b
    end

    # ---- FNV-1a 64 ------------------------------------------------------------
    #
    # The same constants as the reference harness / the independent Python
    # (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`).
    #
    # **The 64 bits are run as two 32-bit halves (hi/lo), and the result is returned as a hex string.**
    # There are 2 reasons, both actually run into:
    #
    # 1. **Written plainly it makes 5 bignum allocations per byte.**
    #    In `h = ((h ^ b) * 0x100000001b3) & 0xffff_ffff_ffff_ffff`, h is unsigned
    #    64-bit and does not fit an `mrb_int`. Measured: hashing 4 239 556 bytes,
    #    `SPINEL_ALLOC_REPORT`'s `(no-scan)` shows **25 438 602 objects / 610 MB**,
    #    **more than 4 times slower** than plain CRuby. Never in the frame loop.
    #    Split into hi/lo, every intermediate fits in 42 bits and the allocations vanish.
    #
    # 2. **`Integer#<<` wraps quietly as signed past 64 bits.**
    #    `(hi << 32) | lo` is negative when hi >= 0x8000_0000, giving a different answer
    #    from CRuby **with no error and no warning**. So no 64-bit integer is ever made;
    #    hi and lo each become 8 hex digits and are concatenated.
    FNV_OFFSET_HI = 0xcbf29ce4
    FNV_OFFSET_LO = 0x84222325
    FNV_PRIME_HI  = 0x100          # 0x100000001b3 = (0x100 << 32) | 0x1b3
    FNV_PRIME_LO  = 0x1b3
    U32_MASK      = 0xffffffff

    # FNV-1a 64 as 16 hex digits. The range version (makes no byteslice).
    def self.fnv1a64_hex_range(s, off, len)
      hi = FNV_OFFSET_HI
      lo = FNV_OFFSET_LO
      i = 0
      while i < len
        x = lo ^ s.getbyte(off + i)               # xor affects only the low byte
        t = x * FNV_PRIME_LO                      # < 2^41
        lo = t & U32_MASK
        hi = (x * FNV_PRIME_HI + hi * FNV_PRIME_LO + (t >> 32)) & U32_MASK
        i += 1
      end
      hex32(hi) + hex32(lo)
    end

    def self.fnv1a64_hex(s)
      fnv1a64_hex_range(s, 0, s.bytesize)
    end

    # 8 hex digits, zero-padded (the reference harness's `%016llx` split into 32 bits each).
    def self.hex32(v)
      s = v.to_s(16)
      s = "0" + s while s.bytesize < 8
      s
    end

    # A mutable byte buffer. **Not made from a literal** (Spinel's
    # string literals are frozen). A port convention.
    def self.buffer(n, fill)
      Array.new(n, fill).pack("C*")
    end

    # Copies a byte string. **The destination is an argument**:
    # `setbyte` on a local read from an ivar makes Spinel lower that String to a
    # handle representation and emit a COW loop that copies the whole buffer twice
    # per byte. The same shape as `Wad#zone_window(lp, cofs, out)`.
    def self.copy(dst, src, n)
      i = 0
      while i < n
        dst.setbyte(i, src.getbyte(i))
        i += 1
      end
      n
    end
  end
end
