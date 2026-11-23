# spinel/grad_rules.rb -- the SPGR surface: differentiable runtime primitives
# with REGISTERED Enzyme rules (E082, P007 Phase 4).
#
#     require_relative "spinel/grad_rules"
#
# Each function here is an ordinary C function (tools/grad/rules/
# spinel_grad_rules_impl.c) that the program links like any other object, and
# an Enzyme rule (spinel_grad_rules_enzyme.c) that spinel-gradgen appends to
# the module whenever a grad_def target calls one.  The ledger of what has a
# rule -- and the kink conventions the rules choose -- is
# tools/grad/rules/rules.tsv; a function absent from that ledger is refused at
# compile time with its name in the message (obstacle `norule`), never
# silently differentiated as zero.
#
# WHY THESE EXIST.  Two shapes of Ruby are differentiable in meaning but not
# in the subset:
#   - `x.clamp(lo, hi)` -- sp_float_clamp_ck reaches sp_str_alloc with no
#     raise on the path, so G2 refuses it (measured, E082).
#   - table interpolation -- indexing by a computed position needs Float#to_i,
#     whose range check reaches sp_str_alloc the same way (E078's `onarrow`).
# SPGR.spg_clamp01 and SPGR.spg_lut1 carry exactly those two meanings across
# the FFI boundary as opaque primitives with hand-written derivative rules.
#
# CONVENTIONS THE CALLER MUST KNOW:
#   - spg_clamp01(u): clamp to [0,1].  Derivative 1 on (0,1), 0 outside and
#     at the boundary points.  Spell clamp(x, lo, hi) as
#     lo + (hi - lo) * SPGR.spg_clamp01((x - lo) / (hi - lo)).
#   - spg_lut1(tab, n, u): piecewise-linear lookup on the UNIT grid, u in
#     [0, n-1], clamped.  Map a real x onto the grid with ordinary Ruby
#     arithmetic ((x - x0) / dx) -- that part is differentiated by Enzyme as
#     usual, and keeping it outside the primitive is what lets ONE registered
#     rule serve every call site (call-site activity, see rules.tsv).
#     No forward rule (Enzyme v0.0.290 limitation): a jvp:/hvp: target that
#     reaches spg_lut1 is refused.
#   - spg_mystery(u): the control -- callable Ruby, but carrying no rule, so
#     grad_def over it demonstrates the norule refusal.
module SPGR
  ffi_func :spg_clamp01, [:double], :double
  ffi_func :spg_lut1, [:float_array, :int64, :double], :double
  ffi_func :spg_mystery, [:double], :double
end
