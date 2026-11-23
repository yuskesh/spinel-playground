# spinel/grad_freestanding.rb -- the `freestanding_grad_def` surface (E079).
#
#     require_relative "spinel/freestanding"
#     require_relative "spinel/grad_freestanding"
#
# ---- WHY A SECOND SPELLING ------------------------------------------------
#
# `grad_def` (spinel/grad.rb, E076) differentiates a method that RUNS as
# ordinary Ruby inside a Spinel program: the primal comes out of `spinel -c`,
# links `libspinel_rt`, writes GC roots, and is only ever called on the host.
#
# `freestanding_grad_def` differentiates a method that has a
# `freestanding_def` boundary: the primal comes out of
# `spinel-mlirgen --freestanding`, has no runtime, no allocator and no GC roots
# AT ALL, and is compiled for thumbv8m / riscv32 / wasm32 as well as the host.
# The adjoint Enzyme synthesises from that IR inherits every one of those
# properties, which is the whole point -- the gradient goes wherever the
# kernel goes (P007 Phase 3).
#
# The two are deliberately NOT the same declaration.  They gate differently:
#
#   grad_def                       freestanding_grad_def
#   ------------------------------ --------------------------------------------
#   G1 type: tools/contract        the freestanding type gate already ran; this
#            reads ntype[id]       declaration only has to check the BOUNDARY
#                                  (returns: :f64, wrt: is an :in f64 buffer)
#   G2 no-alloc: spinel-rtcheck    structural: D-3 stage 2 (undef-check) on the
#            proves it             ADJOINT object -- an allocator would have to
#                                  appear as an undefined symbol, and does not
#   G3 differential vs FD          the same, plus
#   G4 non-triviality              G5: the gradient is BIT-IDENTICAL on all four
#                                  targets (E077's four-way oracle, applied to
#                                  the derivative rather than the function)
#
# ---- KEYWORDS -------------------------------------------------------------
#
#   wrt:    (required) parameter names to differentiate with respect to.  In
#           v1 each must be a buffer parameter declared `[:f64_buf, :in]`.
#           A scalar `wrt:` is refused rather than silently ignored: reverse
#           mode returns an active scalar's derivative through the CALL's
#           return value, which would change the boundary signature -- a v2
#           question, not something to guess at.
#   mode:   :reverse (default).  :forward is P007 Phase 4 and is refused.
#   tol:    the G3 relative-error threshold against central differences.
#           Default 1e-6; the justification is R013 s3.2 / tools/grad/README.
#           It lives in the declaration, not in a flag, so that loosening it
#           shows up in a diff.
#   export: overrides the C symbol.  Default `spinel_grad_<name>`.
#   hvp:    (E084, draft G9-fs) true asks for an ADDITIONAL product next to
#           the reverse adjoint -- forward-over-reverse (E078 s5 / E082 G9's
#           `hvp:` keyword, at the freestanding boundary).  Not a mode: the
#           declaration stays :reverse.  The product's symbol is always
#           `spinel_hvp_<name>` (independent of `export:`), and its boundary
#           inserts `dir`/`g`/`hv` after the wrt buffer, inside the run its
#           `:len` governs:
#
#     /* double spinel_hvp_loss(const double *data, int32_t nd,
#                               const double *w, const double *dir_w,
#                               double *g_w, double *hv_w, int32_t nw);     */
#
#           g receives the gradient, hv its tangent (= H.dir), the return
#           value is grad f . dir -- E082's spg_hvp_* contract.  Requires
#           exactly ONE wrt: buffer (E082 fwd1; more is refused, g12).
#
# The generated boundary is the primal's, with a shadow pointer inserted
# immediately after each `wrt:` buffer, and the primal value as the result:
#
#     freestanding_def :loss, params: [[:f64_buf, :in], :len,
#                                      [:f64_buf, :in], :len], returns: :f64
#     freestanding_grad_def :loss, wrt: :w
#     def loss(data, nd, w, nw) ... end
#
#     /* double spinel_loss     (const double *, int32_t, const double *, int32_t); */
#     /* double spinel_grad_loss(const double *, int32_t,
#                                const double *, double *, int32_t);              */
#
# The shadow is ASSIGNED, not accumulated: the generated shim zeroes it before
# calling Enzyme, so the caller never has to remember to (same contract as
# E076's `spg_grad_*`).
#
# This declaration is INERT to `spinel-mlirgen --freestanding`: adding it to a
# kernel file leaves the generated .mlir/.ll/.o byte-identical.  Only
# `tools/grad/spinel-gradfs` reads it.  Calling it at run time does nothing.
def freestanding_grad_def(name, wrt: [], mode: :reverse, tol: 1.0e-6,
                          export: :"", hvp: false)
  0
end
