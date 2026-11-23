# tools/shader/test/flat_msl.rb — a subject for the MSL lane (Metal directly).
#
# The expression is **identical** to flat.rb. That adding a lane leaves the SPIR-V unchanged
# (MSL is derived by naga) is confirmed by the same sig coming out.
# run_msl_gate.sh rewrites contract: { msl: ... } for three regimes and runs it.

shader_def :flat,
  fragment: { r: :frag2_r, g: :frag2_g, b: :frag2_b, a: 1.0 },
  varyings: { u: :f32, v: :f32 },
  target:   { format: :rgba8unorm },
  lanes:    [:wgsl, :msl],
  contract: { wgsl: :fused, msl: :separate },
  quant:    :half_even,
  coord:    :keep

def frag2_r(u, v)
  u * 0.7 + v * 0.3
end

def frag2_g(u, v)
  a = u * 1.1 - v * 0.4
  a * 0.6 + 0.3
end

def frag2_b(u, v)
  u * u * 0.7 + v * v * 0.3
end
