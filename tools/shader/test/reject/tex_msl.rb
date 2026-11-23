# Refused: textures: with the MSL lane.
shader_def :t,
  attributes: { px: :f32, py: :f32 },
  vertex:     { x: :cx, y: :cy },
  varyings:   { u: :pu, v: :pv },
  textures:   { atlas: { coord: [:u, :v], texel: [:tr, :tg, :tb, :ta] } },
  fragment:   { r: :fr, g: :fg, b: :fb },
  lanes:      [:wgsl, :msl],
  coord:      :keep

def cx(px, py)
  px
end
def cy(px, py)
  py
end
def pu(px, py)
  px
end
def pv(px, py)
  py
end
def fr(u, v, tr, tg, tb, ta)
  tr
end
def fg(u, v, tr, tg, tb, ta)
  tg
end
def fb(u, v, tr, tg, tb, ta)
  tb
end
