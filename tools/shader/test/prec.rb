# tools/shader/test/prec.rb — a subject for the v2 precision contract.
#
# r: one `/` (bound 4 + 2.5 = 6.5 ULP@range)
# g: one `sqrt` (bound 4 + 3 = 7 ULP@range)
# b: both (bound 4 + 2.5 + 3 = 9.5)
#
# It uses **division by a variable**, not by a constant (`u / 4.0`) — a constant division
# becomes correctly rounded when written `u * (1.0/4.0)`, so it would not test
# the contract. The denominator does not cross 1.0 (v + 1.25 ∈ [1.25, 2.25]),
# which rules division by zero and cancellation out of the subject.
shader_def :prec,
  fragment: { r: :prec_r, g: :prec_g, b: :prec_b, a: 1.0 },
  varyings: { u: :f32, v: :f32 },
  target:   { format: :rgba8unorm },
  lanes:    [:wgsl],
  contract: { wgsl: :fused },
  quant:    :half_even,
  coord:    :keep

def prec_r(u, v)
  u / (v + 1.25)
end

def prec_g(u, v)
  Math.sqrt(u * 0.5 + 0.25)
end

def prec_b(u, v)
  Math.sqrt(u + 0.5) / (v + 1.25)
end
