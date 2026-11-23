# A textured subject with no uniform (binding 0 stays empty) and a constant alpha.
shader_def :tex_nouni,
  attributes: { px: :f32, py: :f32, au: :f32, av: :f32 },
  vertex:     { x: :cx, y: :cy },
  varyings:   { u: :pu, v: :pv },
  textures:   { atlas: { coord: [:u, :v], texel: [:tr, :tg, :tb, :ta] } },
  fragment:   { r: :fr, g: :fg, b: :fb, a: 0.5 },
  coord:      :keep

def cx(px, py, au, av)
  px
end

def cy(px, py, au, av)
  py
end

def pu(px, py, au, av)
  au
end

def pv(px, py, au, av)
  av
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
