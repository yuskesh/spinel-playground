# The glyph pass: one textured quad per cell. Compiled to WGSL by tools/shader,
# which samples the atlas once and passes the four components in as tr..ta.
shader_def :glyph,
  attributes: { px: :f32, py: :f32, au: :f32, av: :f32,
                ar: :f32, ag: :f32, ab: :f32, acolor: :f32, afaint: :f32 },
  vertex:     { x: :clip_x, y: :clip_y },
  varyings:   { u: :au, v: :av, fr: :ar, fg: :ag, fb: :ab, color: :acolor, faint: :afaint },
  textures:   { atlas: { coord: [:u, :v], texel: [:tr, :tg, :tb, :ta] } },
  fragment:   { r: :frag_r, g: :frag_g, b: :frag_b, a: :frag_a },
  uniforms:   { width: :f32, height: :f32 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  coord:      :keep

def clip_x(px, py, au, av, ar, ag, ab, acolor, afaint, width, height)
  px / width * 2.0 - 1.0
end

def clip_y(px, py, au, av, ar, ag, ab, acolor, afaint, width, height)
  1.0 - py / height * 2.0
end

# A colour glyph (an emoji) keeps its own pixels; any other takes the cell's
# foreground, with the atlas giving only its coverage.
def frag_r(u, v, fr, fg, fb, color, faint, width, height, tr, tg, tb, ta)
  color * tr + (1.0 - color) * fr
end

def frag_g(u, v, fr, fg, fb, color, faint, width, height, tr, tg, tb, ta)
  color * tg + (1.0 - color) * fg
end

def frag_b(u, v, fr, fg, fb, color, faint, width, height, tr, tg, tb, ta)
  color * tb + (1.0 - color) * fb
end

# Faint dims text only: a colour glyph ignores it.
def frag_a(u, v, fr, fg, fb, color, faint, width, height, tr, tg, tb, ta)
  ta * (color + (1.0 - color) * faint)
end
