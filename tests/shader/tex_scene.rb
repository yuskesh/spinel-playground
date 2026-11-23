# tests/shader/tex_scene.rb — the inputs for the textured drawing checks.
#
#   ruby tex_scene.rb <outdir> glyph <color> <faint>   vb.bin (9 attributes), ub.bin, tex.rgba
#   ruby tex_scene.rb <outdir> plain                   vb.bin (4 attributes), tex.rgba
#
# One quad covering the target, with u running left to right and v top to
# bottom over a 2x2 texture. Every RGBA component differs from the others and
# from the uniform and varying values, so an exchanged argument shows.
# The expected pixels are written by hand in run.sh.
dir, kind, color, faint = ARGV
TEXELS = [16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 184, 208, 224, 240, 200].freeze
CORNERS = [[0.0, 0.0, -1.0, 1.0], [1.0, 0.0, 1.0, 1.0], [0.0, 1.0, -1.0, -1.0],
           [1.0, 0.0, 1.0, 1.0], [1.0, 1.0, 1.0, -1.0], [0.0, 1.0, -1.0, -1.0]].freeze
SCALE = 0.75
floats = CORNERS.flat_map do |u, v, x, y|
  if kind == "glyph"
    [x * SCALE, y * SCALE, u, v, 0.2, 0.4, 0.6, Float(color), Float(faint)]
  else
    [x, y, u, v]
  end
end
File.binwrite(File.join(dir, "vb.bin"), floats.pack("e*"))
File.binwrite(File.join(dir, "ub.bin"), [SCALE].pack("e*")) if kind == "glyph"
File.binwrite(File.join(dir, "tex.rgba"), TEXELS.pack("C*"))
