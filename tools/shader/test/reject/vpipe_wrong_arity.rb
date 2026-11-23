# Refusal: the vertex-world arguments are not all of them in declaration order (the vertex pipeline contract: position is the contract)
shader_def :bad,
  attributes: { ax: :f32, ay: :f32 },
  vertex:     { x: :px, y: :py },
  varyings:   { u: :vu },
  fragment:   { r: :fr, g: :fg, b: :fb, a: 1.0 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep

def px(ax)
  ax
end

def py(ax, ay)
  ay
end

def vu(ax, ay)
  ax
end

def fr(u)
  u
end

def fg(u)
  u
end

def fb(u)
  u
end
