# Refusal 3: an Integer (v1 has Float only)
shader_def :bad,
  fragment: { r: :frag_r, g: :frag_g, b: :frag_b, a: 1.0 },
  target:   { format: :rgba8unorm },
  coord:    :keep

def frag_r(u, v)
  n = 3
  u * v
end

def frag_g(u, v)
  v
end

def frag_b(u, v)
  u
end
