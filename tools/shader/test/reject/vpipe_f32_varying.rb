# Refusal: the vertex pipeline form, but varyings is a type table (:f32) — the two forms mixed (the vertex pipeline contract)
shader_def :bad,
  attributes: { ax: :f32, ay: :f32 },
  vertex:     { x: :px, y: :py },
  varyings:   { u: :f32 },
  fragment:   { r: :fr, g: :fg, b: :fb, a: 1.0 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep
