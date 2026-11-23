# A vertex pipeline whose varyings are attributes passed through unchanged.
# test/pass_explicit.rb is the same shader with the methods written out.
shader_def :pass,
  attributes: { px: :f32, py: :f32, ar: :f32, ag: :f32, ab: :f32 },
  vertex:     { x: :clip_x, y: :clip_y },
  varyings:   { vr: :ar, vg: :ag, vb: :ab },
  fragment:   { r: :frag_r, g: :frag_g, b: :frag_b, a: 1.0 },
  uniforms:   { width: :f32 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep

def clip_x(px, py, ar, ag, ab, width)
  px / width * 2.0 - 1.0
end

def clip_y(px, py, ar, ag, ab, width)
  1.0 - py / width * 2.0
end

def frag_r(vr, vg, vb, width)
  vr
end

def frag_g(vr, vg, vb, width)
  vg * 0.5
end

def frag_b(vr, vg, vb, width)
  vb
end
