# examples/doom/bin/frame_ppm.rb — one rendered frame to PPM, for looking at.
#
#   frame_ppm WAD FRAME.bin W H OUT.ppm
#
# FRAME.bin is an 8-bit indexed screen, W*H bytes, as bin/sim_demo.rb writes
# with its dump_tics argument (frame_<tic>.bin). The colours are the WAD's
# PLAYPAL; a frame has no transparent index. Written here for spinel-extended
# (not imported); lib/doom/ppm.rb does the writing, as for bin/dump_ppm.rb.

require_relative "../lib/doom/wad"
require_relative "../lib/doom/palette"
require_relative "../lib/doom/ppm"

if ARGV.length < 5
  $stderr.puts "usage: frame_ppm WAD FRAME.bin W H OUT.ppm"
  exit 2
end

wad = Doom::Wad.new(ARGV[0])
plane = File.binread(ARGV[1])
w = ARGV[2].to_i
h = ARGV[3].to_i
if plane.bytesize != w * h
  $stderr.puts "frame_ppm: #{ARGV[1]} is #{plane.bytesize} bytes, not #{w}x#{h}"
  exit 1
end
pal = Doom::Palette.new(wad.bytes_by_name("PLAYPAL"))
Doom::Ppm.write(ARGV[4], plane, w, h, pal, -1)
puts "#{ARGV[1]}\t#{w}x#{h}\t#{ARGV[4]}"
