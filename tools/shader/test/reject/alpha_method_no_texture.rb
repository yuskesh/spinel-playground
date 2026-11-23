# Refused: fragment: a: names a method, without a texture to go with it.
shader_def :t,
  fragment: { r: :fr, g: :fr, b: :fr, a: :fr },
  coord:    :keep

def fr(u, v)
  u
end
