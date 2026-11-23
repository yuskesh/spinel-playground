# :ar is an attribute and also a method, so the varying could mean either.
shader_def :pass_clash,
  attributes: { px: :f32, py: :f32, ar: :f32 },
  vertex:     { x: :clip_x, y: :clip_y },
  varyings:   { v: :ar },
  fragment:   { r: :frag_r, g: :frag_r, b: :frag_r, a: 1.0 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep

def clip_x(px, py, ar)
  px
end

def clip_y(px, py, ar)
  py
end

def ar(px, py, ar)
  ar * 2.0
end

def frag_r(v)
  v
end
