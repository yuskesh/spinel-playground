# The same shader name as tex_nouni.rb without the texture: run.sh builds the
# two into one output directory to check the marker and the CPU references.
shader_def :tex_nouni,
  attributes: { px: :f32, py: :f32, au: :f32, av: :f32 },
  vertex:     { x: :cx, y: :cy },
  varyings:   { u: :pu, v: :pv },
  fragment:   { r: :fr, g: :fr, b: :fr },
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

def fr(u, v)
  u
end
