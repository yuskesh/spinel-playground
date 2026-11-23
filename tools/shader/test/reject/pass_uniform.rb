# Only an attribute can be passed through: a uniform is already a fragment argument.
shader_def :pass_uniform,
  attributes: { px: :f32, py: :f32 },
  vertex:     { x: :clip_x, y: :clip_y },
  varyings:   { v: :width },
  fragment:   { r: :frag_r, g: :frag_r, b: :frag_r, a: 1.0 },
  uniforms:   { width: :f32 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep

def clip_x(px, py, width)
  px
end

def clip_y(px, py, width)
  py
end

def frag_r(v, width)
  v
end
