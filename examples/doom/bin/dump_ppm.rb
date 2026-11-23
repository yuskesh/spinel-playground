# doom/bin/dump_ppm.rb — colours an 8-bit index plane with PLAYPAL and writes it as PPM
#
#   dump_ppm WAD OUTDIR NAME [NAME...]
#
# An exit **only for checking by eye**. What the gate rests on is the 8-bit indices
# matching (dump_pictures), not this PPM.
# Transparent pixels are painted magenta (PPM has no transparency).

require_relative "../lib/doom/wad"
require_relative "../lib/doom/picture"
require_relative "../lib/doom/palette"
require_relative "../lib/doom/ppm"

if ARGV.length < 3
  $stderr.puts "usage: dump_ppm WAD OUTDIR NAME [NAME...]"
  exit 2
end

wad = Doom::Wad.new(ARGV[0])
outdir = ARGV[1]
pal = Doom::Palette.new(wad.bytes_by_name("PLAYPAL"))

i = 2
while i < ARGV.length
  name = ARGV[i]
  num = wad.num_for_name(name)
  pic = Doom::Picture.from_wad(wad, num, Doom::Picture::TRANSPARENT)
  path = "#{outdir}/#{name}.ppm"
  Doom::Ppm.write(path, pic.plane, pic.width, pic.height, pal, Doom::Picture::TRANSPARENT)
  puts "#{name}\t#{pic.width}x#{pic.height}\toffset=(#{pic.leftoffset},#{pic.topoffset})\t" \
       "posts=#{pic.posts}\topaque=#{pic.opaque_count}/#{pic.width * pic.height}\t#{path}"
  i += 1
end
