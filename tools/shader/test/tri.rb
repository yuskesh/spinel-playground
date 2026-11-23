# tools/shader/test/tri.rb — a subject for the vertex pipeline form.
#
# A quad of two triangles + a pass-through varying + one uniform. The scene (vertex data) is
# in tri.scene.txt — every edge is at least 0.25 px from any pixel centre
# (the margin rule; the diagonal is 0.354 px too).

shader_def :tri,
  attributes: { ax: :f32, ay: :f32, cu: :f32, cv: :f32 },
  vertex:     { x: :pos_x, y: :pos_y },
  varyings:   { u: :vary_u, v: :vary_v },
  fragment:   { r: :frag_r, g: :frag_g, b: :frag_b, a: 1.0 },
  uniforms:   { t: :f32 },
  target:     { format: :rgba8unorm },
  lanes:      [:wgsl],
  contract:   { wgsl: :fused },
  quant:      :half_even,
  coord:      :keep

def pos_x(ax, ay, cu, cv, t)
  ax
end

def pos_y(ax, ay, cu, cv, t)
  ay
end

def vary_u(ax, ay, cu, cv, t)
  cu
end

def vary_v(ax, ay, cu, cv, t)
  cv
end

def frag_r(u, v, t)
  u * t * 0.5
end

def frag_g(u, v, t)
  v * 0.7 + 0.1
end

def frag_b(u, v, t)
  u * v * t * 0.3 + 0.05
end
