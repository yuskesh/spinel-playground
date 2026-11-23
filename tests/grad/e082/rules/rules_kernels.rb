# E082 -- the custom-rule surface: two meanings that were UNWRITABLE in the
# differentiable subset until now.
#
#   - table interpolation needed Float#to_i (refused: E078 `onarrow`, O5 --
#     sp_float_to_i_checked reaches sp_str_alloc with no raise on the path)
#   - clamp needed Float#clamp (refused the same way: sp_float_clamp_ck ->
#     sp_float_to_s -> sp_str_alloc, measured in this experiment)
#
# SPGR (tools/grad/spinel/grad_rules.rb) carries both across the FFI boundary
# as opaque primitives with REGISTERED Enzyme rules; the ledger is
# tools/grad/rules/rules.tsv.  Everything else here is ordinary Ruby.
require_relative "spinel/grad"
require_relative "spinel/grad_rules"

# Piecewise-linear LUT loss.  The unit-grid mapping (x - x0) / dx happens in
# Ruby ON PURPOSE (differentiable there; keeping scalars out of the primitive
# is what lets one registered rule serve every call site -- rules.tsv).
grad_def :lut_loss, wrt: [:x], tol: 1.0e-6,
         probe: [[[0.5, 1.5, 2.2], 3, [0.0, 1.0, 4.0, 9.0], 4],
                 [[0.25, 2.75, 1.1], 3, [2.0, -1.0, 3.0, 0.5], 4]]
def lut_loss(x, n, tab, m)
  s = 0.0
  i = 0
  while i < n
    y = SPGR.spg_lut1(tab, m, x[i])
    s += y * y
    i += 1
  end
  s
end

# General clamp(v, lo, hi) spelled through the [0,1] primitive:
#   lo + (hi - lo) * clamp01((v - lo) / (hi - lo)),  lo = 0.25, hi = 1.75.
# spg_clamp01 has BOTH rules (reverse + forward), so hvp:/jvp: are allowed --
# this is the one place the whole new vocabulary meets: a custom rule, its
# forward rule, and forward-over-reverse across both.
grad_def :clamp_loss, wrt: [:x], tol: 1.0e-6, hvp: true, jvp: true,
         probe: [[[0.3, -0.4, 1.9, 0.75], 4],
                 [[0.6, 0.2, -1.0, 2.5], 4]]
def clamp_loss(x, n)
  s = 0.0
  i = 0
  while i < n
    v = 0.25 + 1.5 * SPGR.spg_clamp01((x[i] - 0.25) / 1.5)
    s += v * v * 0.5
    i += 1
  end
  s
end

puts lut_loss([0.5, 1.5, 2.2], 3, [0.0, 1.0, 4.0, 9.0], 4)
puts clamp_loss([0.3, -0.4, 1.9, 0.75], 4)
