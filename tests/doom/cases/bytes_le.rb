# doom/test/bytes_le.rb — all of Doom::Bytes (little-endian reads, names, hashes)
#
# Run: bytes_le [SCRATCHDIR]   (this test does not use the scratch directory)
# Oracle: equal to `.expected` **and** equal to CRuby.

require_relative "../../../examples/doom/lib/doom/bytes"

B = Doom::Bytes

s = Array.new(16, 0).pack("C*")
s.setbyte(0, 0x34); s.setbyte(1, 0x12)
s.setbyte(2, 0xff); s.setbyte(3, 0xff)
s.setbyte(4, 0x78); s.setbyte(5, 0x56); s.setbyte(6, 0x34); s.setbyte(7, 0x12)
s.setbyte(8, 0x00); s.setbyte(9, 0x00); s.setbyte(10, 0x00); s.setbyte(11, 0x80)

puts "u8   = #{B.u8(s, 0)}"
puts "u16  = #{B.u16(s, 0)}"
puts "i16+ = #{B.i16(s, 0)}"
puts "i16- = #{B.i16(s, 2)}"
puts "u32  = #{B.u32(s, 4)}"
puts "i32  = #{B.i32(s, 4)}"
puts "i32- = #{B.i32(s, 8)}"

# Names: NUL-terminated / exactly 8 characters (no NUL) / NUL first
n = Array.new(24, 0).pack("C*")
"E1M1".each_byte.with_index { |c, i| n.setbyte(i, c) }
"PLAYPALX".each_byte.with_index { |c, i| n.setbyte(8 + i, c) }
puts "name8 short  = #{B.name8(n, 0).inspect}"
puts "name8 full8  = #{B.name8(n, 8).inspect}"
puts "name8 empty  = #{B.name8(n, 16).inspect}"

# FNV-1a 64: known vectors (empty, "a" and "foobar" are FNV's published test vectors)
puts "fnv('')       = #{B.fnv1a64_hex(Array.new(0, 0).pack('C*'))}"
a = Array.new(1, 97).pack("C*")
puts "fnv('a')      = #{B.fnv1a64_hex(a)}"
fb = Array.new(6, 0).pack("C*")
"foobar".each_byte.with_index { |c, i| fb.setbyte(i, c) }
puts "fnv('foobar') = #{B.fnv1a64_hex(fb)}"

# Always pass one input that lands on hi >= 0x80000000 (the shape that makes
# `<<` wrap around)
big = Array.new(256, 0).pack("C*")
i = 0
while i < 256
  big.setbyte(i, i)
  i += 1
end
puts "fnv(0..255)   = #{B.fnv1a64_hex(big)}"
puts "fnv(range)    = #{B.fnv1a64_hex_range(big, 16, 32)}"

puts "hex32 = #{B.hex32(0)} #{B.hex32(0x1b3)} #{B.hex32(0xffffffff)}"
buf = B.buffer(5, 255)
puts "buffer = #{buf.bytesize} #{buf.getbyte(0)} #{buf.getbyte(4)}"
buf.setbyte(2, 7)
puts "buffer mutable = #{buf.getbyte(2)}"
