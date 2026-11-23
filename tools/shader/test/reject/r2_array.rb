# Refusal 2: an Array (it allocates, so it cannot be mapped to a shader)
shader_def :bad,
  fragment: { r: :frag_r, g: :frag_g, b: :frag_b, a: 1.0 },
  target:   { format: :rgba8unorm },
  coord:    :keep

def frag_r(u, v)
  a = [u, v]
  a[0] * a[1]
end

def frag_g(u, v)
  v
end

def frag_b(u, v)
  u
end
