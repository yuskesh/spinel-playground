# Refusal: vertex: without attributes: (the vertex pipeline contract: write both or neither)
shader_def :bad,
  vertex:   { x: :px, y: :py },
  varyings: { u: :vu, v: :vv },
  fragment: { r: :fr, g: :fg, b: :fb, a: 1.0 },
  target:   { format: :rgba8unorm },
  lanes:    [:wgsl],
  contract: { wgsl: :fused },
  quant:    :half_even,
  coord:    :keep
