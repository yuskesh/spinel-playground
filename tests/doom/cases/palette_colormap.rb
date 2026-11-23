# doom/test/palette_colormap.rb — PLAYPAL, COLORMAP and a **bare `if @ivar`**
#
# Run: palette_colormap [SCRATCHDIR]  (the scratch directory is not used)
# Oracle: equal to `.expected` **and** equal to CRuby.
#
# The second purpose of this test is to write, **as it is and not worked
# around**, the shape of a Spinel defect that was once fixed upstream, and to
# confirm the fix from the ported code:
#     (1) `@colormap` is initialised to `nil` in `initialize`,
#     (2) it is assigned only through the writer `attr_accessor` makes,
#     (3) it is read by the bare `if @colormap` in `Doom::Palette#resolve`.
#   Before the fix (61ffe24e) the guard folded to always-false and the branch
#   vanished, so a colormap had no effect; with the fix (8154ec0c) the output
#   equals CRuby's.

require_relative "../../../examples/doom/lib/doom/palette"

# --- A synthetic PLAYPAL: two palettes. Colour i is (i, 255-i, (i*7)&0xff);
#     the second palette adds 1 to R only.
pal = Doom::Bytes.buffer(2 * 768, 0)
i = 0
while i < 256
  pal.setbyte(i * 3, i)
  pal.setbyte(i * 3 + 1, 255 - i)
  pal.setbyte(i * 3 + 2, (i * 7) & 0xff)
  pal.setbyte(768 + i * 3, (i + 1) & 0xff)
  pal.setbyte(768 + i * 3 + 1, 255 - i)
  pal.setbyte(768 + i * 3 + 2, (i * 7) & 0xff)
  i += 1
end

# --- A synthetic COLORMAP: three rows. Row 0 is not the identity (it maps 7
#     to 200), row 1 adds 1, row 2 is all 0.
cm = Doom::Bytes.buffer(3 * 256, 0)
i = 0
while i < 256
  cm.setbyte(i, i)
  cm.setbyte(256 + i, (i + 1) & 0xff)
  cm.setbyte(512 + i, 0)
  i += 1
end
cm.setbyte(7, 200)

p = Doom::Palette.new(pal)
puts "npals=#{p.count} selected=#{p.selected}"
puts "rgb(7) no colormap  = #{p.r(7)},#{p.g(7)},#{p.b(7)}"

# (3) Through the bare `if @colormap`: no colormap is set, so values pass through
c = Doom::Colormap.new(cm)
puts "colormap rows=#{c.rows} identity_row0=#{c.identity_row0?} brightest(7)=#{c.brightest(7)}"

# (2) Assign only through attr_accessor
p.colormap = c
puts "rgb(7) colormap row0 = #{p.r(7)},#{p.g(7)},#{p.b(7)}"   # 7 -> 200
p.light = 1
puts "rgb(7) colormap row1 = #{p.r(7)},#{p.g(7)},#{p.b(7)}"   # 7 -> 8
p.light = 2
puts "rgb(7) colormap row2 = #{p.r(7)},#{p.g(7)},#{p.b(7)}"   # 7 -> 0

# Switch the palette
p.select(1)
p.light = 0
puts "pal1 rgb(7) = #{p.r(7)},#{p.g(7)},#{p.b(7)}"

# Removing the colormap passes values through again (the ivar back to nil)
p.colormap = nil
p.select(0)
puts "rgb(7) colormap off = #{p.r(7)},#{p.g(7)},#{p.b(7)}"

# --- Refusals ---
begin
  Doom::Palette.new(Doom::Bytes.buffer(100, 0))
rescue Doom::PaletteError => err
  puts "reject PLAYPAL: #{err.message}"
end
begin
  Doom::Colormap.new(Doom::Bytes.buffer(100, 0))
rescue Doom::PaletteError => err
  puts "reject COLORMAP: #{err.message}"
end
begin
  p.select(9)
rescue Doom::PaletteError => err
  puts "reject select: #{err.message}"
end
