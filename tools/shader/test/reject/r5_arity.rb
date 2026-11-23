# Refusal 5: the argument count (the convention is one method = two arguments)
shader_def :bad,
  fragment: { r: :frag_r, g: :frag_g, b: :frag_b, a: 1.0 },
  target:   { format: :rgba8unorm },
  coord:    :keep

def frag_r(u, v, w)
  u * v * w
end

def frag_g(u, v)
  v
end

def frag_b(u, v)
  u
end
