# doom/test/wad_and_picture.rb — fixes what the WAD reader and the picture
# decoder mean, with a synthetic WAD
#
# Run: wad_and_picture SCRATCHDIR
# Oracle: equal to `.expected` **and** equal to CRuby.
#
# No real IWAD is needed (so that it can run anywhere and no WAD is
# committed). Agreement with a real IWAD is checked against the reference
# implementation by `tools/run_gates.sh`.

require_relative "../../../examples/doom/lib/doom/wad"
require_relative "../../../examples/doom/lib/doom/picture"

scratch = ARGV.length > 0 ? ARGV[0] : "."

def put16(s, o, v)
  s.setbyte(o, v & 0xff)
  s.setbyte(o + 1, (v >> 8) & 0xff)
end

def put32(s, o, v)
  s.setbyte(o, v & 0xff)
  s.setbyte(o + 1, (v >> 8) & 0xff)
  s.setbyte(o + 2, (v >> 16) & 0xff)
  s.setbyte(o + 3, (v >> 24) & 0xff)
end

def putname(s, o, name)
  i = 0
  while i < name.bytesize
    s.setbyte(o + i, name.getbyte(i))
    i += 1
  end
end

# --- Build a synthetic WAD ----------------------------------------------------
#
# Four lumps:
#   0 E1M1    size 0            (a map marker, for map_lump)
#   1 PIC     a 4x3 patch       (with a transparent gap)
#   2 DUP     size 0
#   3 DUP     size 0            (the same name: the later one wins)
#
# PIC's contents (x is the column):
#   column 0: 11 at y=0, 33 at y=2   (y=1 is transparent)
#   column 1: empty (only 0xff: all transparent)
#   column 2: 44,55 at y=1..2
#   column 3: 66,77,88 at y=0..2

pic_hdr = 8 + 4 * 4
col0 = [0, 1, 11, 11, 11, 2, 1, 33, 33, 33, 0xff]
col1 = [0xff]
col2 = [1, 2, 44, 44, 55, 55, 0xff]
col3 = [0, 3, 66, 66, 77, 88, 88, 0xff]
body = col0 + col1 + col2 + col3
piclen = pic_hdr + body.length

pic = Doom::Bytes.buffer(piclen, 0)
put16(pic, 0, 4)          # width
put16(pic, 2, 3)          # height
put16(pic, 4, 0xfffb)     # leftoffset = -5
put16(pic, 6, 7)          # topoffset
put32(pic, 8, pic_hdr)
put32(pic, 12, pic_hdr + col0.length)
put32(pic, 16, pic_hdr + col0.length + col1.length)
put32(pic, 20, pic_hdr + col0.length + col1.length + col2.length)
i = 0
while i < body.length
  pic.setbyte(pic_hdr + i, body[i])
  i += 1
end

wadlen = 12 + piclen + 4 * 16
wad = Doom::Bytes.buffer(wadlen, 0)
putname(wad, 0, "IWAD")
put32(wad, 4, 4)              # numlumps
put32(wad, 8, 12 + piclen)    # infotableofs
i = 0
while i < piclen
  wad.setbyte(12 + i, pic.getbyte(i))
  i += 1
end
d = 12 + piclen
put32(wad, d, 0);        put32(wad, d + 4, 0);       putname(wad, d + 8, "E1M1")
put32(wad, d + 16, 12);  put32(wad, d + 20, piclen); putname(wad, d + 24, "PIC")
put32(wad, d + 32, 0);   put32(wad, d + 36, 0);      putname(wad, d + 40, "DUP")
put32(wad, d + 48, 0);   put32(wad, d + 52, 0);      putname(wad, d + 56, "DUP")

path = "#{scratch}/synth.wad"
File.open(path, "wb") { |f| f.write(wad) }

# --- Read ---------------------------------------------------------------------

w = Doom::Wad.new(path)
puts "magic=#{w.magic} bytes=#{w.bytesize} lumps=#{w.count}"
i = 0
while i < w.count
  l = w.lump(i)
  puts "lump #{l.index} #{l.name} pos=#{l.pos} size=#{l.size} marker=#{l.marker?} fnv=#{w.fnv1a64_hex(i)}"
  i += 1
end
puts "index_of(DUP)=#{w.index_of('DUP')}   # a duplicate name: the later one wins"
puts "index_of(PIC)=#{w.index_of('PIC')}"
puts "index_of(NOPE)=#{w.index_of('NOPE')}"
puts "map_lump(E1M1,PIC)=#{w.map_lump('E1M1', 'PIC')}"
puts "map_lump(E1M1,NOPE)=#{w.map_lump('E1M1', 'NOPE')}"
puts "map_lump(NOPE,PIC)=#{w.map_lump('NOPE', 'PIC')}"
puts "bytes(PIC).bytesize=#{w.bytes_by_name('PIC').bytesize}"

# --- Decode -------------------------------------------------------------------

p1 = Doom::Picture.from_wad(w, w.num_for_name("PIC"), Doom::Picture::TRANSPARENT)
puts "pic #{p1.width}x#{p1.height} left=#{p1.leftoffset} top=#{p1.topoffset} " \
     "posts=#{p1.posts} pixels=#{p1.pixels} opaque=#{p1.opaque_count} fnv=#{p1.fnv1a64_hex}"
y = 0
while y < p1.height
  row = ""
  x = 0
  while x < p1.width
    row = row + "#{p1.at(x, y)} "
    x += 1
  end
  puts "row#{y}: #{row}"
  y += 1
end

# Changing the background marker changes only the gaps (what transparent means)
p2 = Doom::Picture.from_wad(w, w.num_for_name("PIC"), 0)
diff = 0
i = 0
n = p1.width * p1.height
while i < n
  diff += 1 if p1.plane.getbyte(i) != p2.plane.getbyte(i)
  i += 1
end
puts "bg255 vs bg0: differing pixels=#{diff} (= the transparent pixels)"
puts "opaque(bg=0)=#{p2.opaque_count}"
