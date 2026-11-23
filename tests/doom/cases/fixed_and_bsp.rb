# doom/test/fixed_and_bsp.rb — a guard for the fixed-point and table code
# that needs no IWAD.
#
# It watches three things:
#
#   1. `Doom::Fixed`'s four operations give "values known to match the
#      reference implementation". The table values are **the reference
#      implementation's answers**, taken from a comparison of 242,514 pairs.
#      They include `FixedDiv`'s `abs(INT_MIN)` path and the trap of taking C's
#      truncation toward zero for Ruby's flooring division.
#   2. `Doom::Tables`'s embedded tables are intact (element counts and sample
#      values). **The binary String literals contain `\x00` and `\xff`**, so a
#      change in literal handling fails here first.
#   3. `Renderer`'s inline 32-bit and 16-bit truncation expressions mean the
#      same as `Doom::Fixed` (the guarantee behind the porting convention that
#      allows them).

require_relative "../../../examples/doom/lib/doom/fixed"
require_relative "../../../examples/doom/lib/doom/tables"

M32 = 0xffffffff
SGN = 0x80000000
M16 = 0xffff
SGN16 = 0x8000

def show(label, got, want)
  puts "#{label} #{got} #{got == want ? 'ok' : "MISMATCH(want #{want})"}"
end

# ---- 1. FixedMul ------------------------------------------------------------
# a, b, the reference implementation's FixedMul
MUL = [[65536, 65536, 65536],
       [65536, -65536, -65536],
       [1073741824, 1073741824, 0],                 # 2^30 * 2^30 >> 16 collapses to 0 in 32 bits
       [2147483647, 2147483647, -65536],
       [-2147483648, 65536, -2147483648],
       [-2147483648, 65537, 2147450880],
       [-65536, 7, -7],
       [65535, -65535, -65535],
       [0, -2147483648, 0]]
MUL.each do |row|
  show("mul(#{row[0]},#{row[1]})", Doom::Fixed.mul(row[0], row[1]), row[2])
end

# ---- 2. FixedDiv ------------------------------------------------------------
# The negative-division trap: C truncates toward zero, Ruby's `/` floors.
DIV = [[65536, 65536, 65536],
       [1, 65536, 1],
       [-65536, 7, -613566756],                     # C truncates toward zero; flooring is off by 1
       [65535, -65535, -65536],
       [16384, 1, 2147483647],                      # the abs(a)>>14 >= abs(b) guard
       [-16384, 1, -2147483648],
       [-2147483648, 4194303, -33554440],           # the path where abs(INT_MIN) behaves as non-negative
       [0, -2147483648, 0],
       [-2147483648, 1, -2147483648]]
DIV.each do |row|
  show("div(#{row[0]},#{row[1]})", Doom::Fixed.div(row[0], row[1]), row[2])
end

# ---- 3. to_i32 / bam --------------------------------------------------------
show("to_i32(2^31)", Doom::Fixed.to_i32(2147483648), -2147483648)
show("to_i32(2^32+5)", Doom::Fixed.to_i32(4294967301), 5)
show("to_i32(-1)", Doom::Fixed.to_i32(-1), -1)
show("bam(-1)", Doom::Fixed.bam(-1), 4294967295)
show("bam(2^32)", Doom::Fixed.bam(4294967296), 0)
show("cdiv(-7,2)", Doom::Fixed.cdiv(-7, 2), -3)
show("cdiv(7,-2)", Doom::Fixed.cdiv(7, -2), -3)

# ---- 4. Do the inline expressions mean the same as Doom::Fixed? -----------
bad32 = 0
bad16 = 0
badmul = 0
# Draw a deterministic 31-bit LCG twice to make values within ±2^46.
# **It is held to 31 bits so that `v * 1103515245` stays below 2^63**: past
# that, Spinel raises `RangeError` under its default `--int-overflow=raise`
# while CRuby silently promotes to a Bignum, and **the answers split**.
i = 0
v = 12345
while i < 4000
  v = (v * 1103515245 + 12345) & 0x7fffffff
  hi = v - 0x40000000
  v = (v * 1103515245 + 12345) & 0x7fffffff
  x = hi * 65536 + (v & 0xffff)
  bad32 += 1 if (((x & M32) ^ SGN) - SGN) != Doom::Fixed.to_i32(x)
  bad16 += 1 if (((x & M16) ^ SGN16) - SGN16) != ((x & 0xffff) >= 0x8000 ? (x & 0xffff) - 0x10000 : (x & 0xffff))
  a = Doom::Fixed.to_i32(x)
  b = Doom::Fixed.to_i32(x >> 7)
  badmul += 1 if ((((a) * (b) >> 16 & M32) ^ SGN) - SGN) != Doom::Fixed.mul(a, b)
  i += 1
end
puts "inline to_i32 mismatches #{bad32}"
puts "inline to_i16 mismatches #{bad16}"
puts "inline mul mismatches #{badmul}"

# ---- 5. The embedded tables ------------------------------------------------
fs = Doom::Tables.finesine
ft = Doom::Tables.finetangent
ta = Doom::Tables.tantoangle
puts "finesine #{fs.length} #{fs[0]} #{fs[2048]} #{fs[10239]}"
puts "finetangent #{ft.length} #{ft[0]} #{ft[2048]} #{ft[4095]}"
puts "tantoangle #{ta.length} #{ta[0]} #{ta[1]} #{ta[2048]}"

sum = 0
i = 0
while i < fs.length
  sum = (sum + fs[i]) % 1000000007
  i += 1
end
puts "finesine sum #{sum}"
