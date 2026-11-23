# Refused: textures: in the form without vertex:.
shader_def :t,
  varyings: { u: :f32, v: :f32 },
  textures: { atlas: { coord: [:u, :v], texel: [:tr, :tg, :tb, :ta] } },
  fragment: { r: :fr, g: :fr, b: :fr },
  coord:    :keep

def fr(u, v)
  u
end
