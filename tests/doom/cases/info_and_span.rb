# doom/test/info_and_span.rb
#
# Two tests that need no IWAD.
#
# 1. `Doom::Info`: the three tables generated from `info.c` (sprnames, states,
#    mobjinfo) unpack correctly. It guards that a binary String literal unpacks
#    the same in Spinel and in CRuby. It also checks the total checksums, so a
#    regeneration that silently changes the contents fails here.
#
# 2. `R_DrawSpan`'s **packed position** arithmetic: the reference
#    implementation (doomgeneric, of the Chocolate Doom line) packs x and y into
#    one 32-bit word. Its **answer differs** from linuxdoom's
#    `((yfrac>>10)&4032) + ((xfrac>>16)&63)` (observed as a difference of
#    1,025 pixels). This test compares the two expressions over a deterministic
#    sequence and records both that they differ and the packed version's values.

require_relative "../../../examples/doom/lib/doom/info"

M32 = 0xffffffff

def spot_packed(xfrac, yfrac, xstep, ystep, i)
  position = ((((xfrac & M32) << 10) & 0xffff0000) | (((yfrac & M32) >> 6) & 0xffff)) & M32
  step = ((((xstep & M32) << 10) & 0xffff0000) | (((ystep & M32) >> 6) & 0xffff)) & M32
  k = 0
  while k < i
    position = (position + step) & M32
    k += 1
  end
  (position >> 26) | ((position >> 4) & 0x0fc0)
end

def spot_linuxdoom(xfrac, yfrac, xstep, ystep, i)
  xf = (xfrac + xstep * i) & M32
  yf = (yfrac + ystep * i) & M32
  ((yf >> 10) & 4032) + ((xf >> 16) & 63)
end

def main
  sprnames = Doom::Info.sprnames
  ss = Doom::Info.state_sprite
  sf = Doom::Info.state_frame
  st = Doom::Info.state_tics
  sn = Doom::Info.state_nextstate
  md = Doom::Info.mobj_doomednum
  mspawn = Doom::Info.mobj_spawnstate
  mr = Doom::Info.mobj_radius
  mh = Doom::Info.mobj_height
  mf = Doom::Info.mobj_flags

  puts "sprnames=#{sprnames.length} states=#{ss.length} mobjinfo=#{md.length}"
  puts "sprname[0]=#{sprnames[0]} sprname[3]=#{sprnames[3]} sprname[137]=#{sprnames[137]}"
  # S_PISTOLUP = 12 -> SPR_PISG (3), frame 0, tics 1
  puts "state12=#{ss[12]},#{sf[12]},#{st[12]},#{sn[12]}"
  # MT_PLAYER = 0 (doomednum -1), MT_POSSESSED = 1 (doomednum 3004)
  puts "mobj0=#{md[0]},#{mspawn[0]},#{mr[0]},#{mh[0]},#{mf[0]}"
  puts "mobj1=#{md[1]},#{mspawn[1]},#{mr[1]},#{mh[1]},#{mf[1]}"

  a = 0
  b = 0
  i = 0
  while i < ss.length
    a = (a + ss[i] * 7 + sf[i] * 11 + st[i] * 13 + sn[i] * 17) & 0x3fffffff
    i += 1
  end
  i = 0
  while i < md.length
    b = (b + md[i] * 7 + mspawn[i] * 11 + mr[i] + mh[i] + (mf[i] & 0xffff)) & 0x3fffffff
    i += 1
  end
  puts "states_checksum=#{a} mobjinfo_checksum=#{b}"

  # Compare the two spot expressions over a deterministic sequence (inputs
  # from xorshift32).
  s = 0x1d872b41
  diff = 0
  same = 0
  n = 0
  while n < 500
    s ^= (s << 13) & M32
    s &= M32
    s ^= s >> 17
    s ^= (s << 5) & M32
    s &= M32
    xfrac = s
    s ^= (s << 13) & M32
    s &= M32
    s ^= s >> 17
    s ^= (s << 5) & M32
    s &= M32
    yfrac = s
    xstep = ((s >> 8) & 0x3ffff) - 0x1ffff
    ystep = ((s >> 4) & 0x3ffff) - 0x1ffff
    i = 0
    while i < 8
      p = spot_packed(xfrac, yfrac, xstep, ystep, i)
      l = spot_linuxdoom(xfrac, yfrac, xstep, ystep, i)
      if p == l
        same += 1
      else
        diff += 1
      end
      i += 1
    end
    n += 1
  end
  puts "spot packed==linuxdoom: same=#{same} diff=#{diff}"
  puts "spot_packed sample=#{spot_packed(65304169, 233085329, 24294, 0, 77)}"
  puts "spot_linuxdoom sample=#{spot_linuxdoom(65304169, 233085329, 24294, 0, 77)}"
end

main
