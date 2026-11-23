# A textured subject in the shape of a terminal glyph: nine attributes, seven
# varyings, one uniform, and an alpha method. textures: spans several lines on
# purpose (tests/shader/run.sh checks that the signature still sees it).
shader_def :tex,
  attributes: { px: :f32, py: :f32, au: :f32, av: :f32,
                ar: :f32, ag: :f32, ab: :f32, acolor: :f32, afaint: :f32 },
  vertex:     { x: :clip_x, y: :clip_y },
  varyings:   { u: :pass_u, v: :pass_v, fr: :pass_r, fg: :pass_g, fb: :pass_b,
                color: :pass_color, faint: :pass_faint },
  textures:   {
    atlas: {
      coord: [:u, :v],
      texel: [:tr, :tg, :tb, :ta]
    }
  },
  fragment:   { r: :frag_r, g: :frag_g, b: :frag_b, a: :frag_a },
  uniforms:   { scale: :f32 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  coord:      :keep

def clip_x(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  px / scale
end

def clip_y(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  py / scale
end

def pass_u(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  au
end

def pass_v(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  av
end

def pass_r(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  ar
end

def pass_g(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  ag
end

def pass_b(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  ab
end

def pass_color(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  acolor
end

def pass_faint(px, py, au, av, ar, ag, ab, acolor, afaint, scale)
  afaint
end

def frag_r(u, v, fr, fg, fb, color, faint, scale, tr, tg, tb, ta)
  color * tr + (1.0 - color) * fr
end

def frag_g(u, v, fr, fg, fb, color, faint, scale, tr, tg, tb, ta)
  color * tg + (1.0 - color) * fg
end

def frag_b(u, v, fr, fg, fb, color, faint, scale, tr, tg, tb, ta)
  color * tb + (1.0 - color) * fb
end

def frag_a(u, v, fr, fg, fb, color, faint, scale, tr, tg, tb, ta)
  ta * (color + (1.0 - color) * faint)
end
