# The solid-colour rectangles behind the text: cell backgrounds, the cursor,
# underlines and strikethroughs. Compiled to WGSL by tools/shader.
shader_def :quad,
  attributes: { px: :f32, py: :f32, ar: :f32, ag: :f32, ab: :f32 },
  vertex:     { x: :clip_x, y: :clip_y },
  varyings:   { vr: :ar, vg: :ag, vb: :ab },
  fragment:   { r: :frag_r, g: :frag_g, b: :frag_b, a: 1.0 },
  uniforms:   { width: :f32, height: :f32 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep

def clip_x(px, py, ar, ag, ab, width, height)
  px / width * 2.0 - 1.0
end

def clip_y(px, py, ar, ag, ab, width, height)
  1.0 - py / height * 2.0
end

def frag_r(vr, vg, vb, width, height)
  vr
end

def frag_g(vr, vg, vb, width, height)
  vg
end

def frag_b(vr, vg, vb, width, height)
  vb
end
