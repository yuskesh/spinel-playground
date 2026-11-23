# tools/shader/test/flat.rb — a subject for spinel-rb2spv.
#
# The **same expression** as the prototype's frag2.rb (the coefficients are not powers of 2, so f32 rounding and
# FMA contraction really happen; in frag.rb everything was exact by chance and the instrument did nothing).
# The expression is unchanged so that byte equality of SPIR-V with the prototype can be checked.

shader_def :flat,
  fragment: { r: :frag2_r, g: :frag2_g, b: :frag2_b, a: 1.0 },
  varyings: { u: :f32, v: :f32 },
  target:   { format: :rgba8unorm },
  lanes:    [:wgsl],
  contract: { wgsl: :fused },
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
