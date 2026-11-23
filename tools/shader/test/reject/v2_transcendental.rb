# Refusal: Math.sin is refused in v2 too — the error of a transcendental function depends on the size of its input,
# so the composition rule of the v2 precision contract (adding constant ULPs) cannot state an upper bound
shader_def :bad,
  fragment: { r: :fr, g: :fg, b: :fb, a: 1.0 },
  varyings: { u: :f32, v: :f32 },
  target: { format: :rgba8unorm }, lanes: [:wgsl],
  contract: { wgsl: :fused }, quant: :half_even, coord: :keep

def fr(u, v)
  Math.sin(u)
end

def fg(u, v)
  v
end

def fb(u, v)
  u
end
