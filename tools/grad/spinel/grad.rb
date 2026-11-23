# spinel/grad.rb -- the user-facing `grad_def` surface (E076, R013 s6.1 design).
#
# Shipped as a source library and pulled in with
#
#     require_relative "spinel/grad"
#
# which spinel resolves at COMPILE time (textual insertion, src/spinel_parse.c
# resolve_requires), so the declaration below is visible both to the compiler
# and to `tools/grad/spinel-gradgen`, which reads it back out of `--dump-ast`.
# Exactly the shape `freestanding_def` (tools/freestanding/spinel/freestanding.rb)
# and `tensor_def` (tools/tensor/spinel/tensor.rb) already have.
#
# ---- WHAT IS DIFFERENT FROM THE OTHER TWO DECLARATIONS ---------------------
#
# `tensor_def` and `freestanding_def` mark a body that is NEVER RUN: the body
# is a declaration the generator compiles to somewhere else (linalg / a wasm
# object), and calling it raises.  `grad_def` marks a body that is ORDINARY
# RUBY AND RUNS.  Nothing about the method changes; the declaration only says
#
#     "also synthesise the derivative of this method, and gate it."
#
# That is the whole surface.  There is no autograd engine, no tape, no tensor
# type: the derivative is produced by Enzyme (docs/tools/enzyme.md) from the
# LLVM IR that `spinel -c` + clang already produce for the method, and the
# only thing this file adds to the program is a no-op call.
#
# ---- THE FOUR GATES --------------------------------------------------------
#
# R013 s3.3 measured that a differentiated INTEGER method comes back as silent
# garbage: Enzyme builds an empty adjoint, emits no diagnostic, and the
# caller reads whatever was in the return register (a value that is
# DETERMINISTIC and wrong -- the worst shape a bug can have).  So the surface
# is not "declare and hope"; every declaration passes four gates before an
# object file exists (R013 s6.2, E076):
#
#   G1  type      -- the target is a Float pure function over the subset.
#                    Read out of the compiler's own inference (tools/contract,
#                    node-id based, NOT the (line,col) join).  This is what
#                    structurally prevents the empty adjoint.
#   G2  no-alloc  -- tools/realtime/spinel-rtcheck proves the target cannot
#                    allocate, hence cannot collect, hence needs no GC roots.
#                    Enzyme refuses any function that writes @sp_gc_roots; the
#                    admission is what makes removing them sound (E017).
#   G3  differential -- every probe point: |enzyme - fd| / max(1,|fd|) < tol.
#   G4  non-triviality -- the gradient is not identically zero.  R013 s4.1 hit
#                    a relu-saturated network where Enzyme and finite
#                    differences agreed on 0.0 and G3 stayed green.
#
# ---- KEYWORDS --------------------------------------------------------------
#
#   wrt:    (required) the parameter names to differentiate with respect to.
#           A Symbol or an Array of Symbols.  Everything else is held constant
#           (`enzyme_const`).  Each named parameter must be inferred Float or
#           Array[Float].
#   mode:   :reverse (default).  :forward is Phase 4 and is refused loudly
#           rather than silently ignored.
#   tol:    the G3 relative-error threshold.  Default 1e-6.  It is written in
#           the DECLARATION, not in a flag, so that loosening it shows up in a
#           diff.  Justification for the default: R013 s3.2 -- the central
#           difference noise floor for double is eps^(2/3) ~ 3.7e-11, so 1e-6
#           is ~5 decades above the floor and ~5 decades below the O(1)
#           relative error a dropped term produces.
#   probe:  the points G3 and G4 evaluate at, as an Array of argument lists.
#           A Float argument is a Float; an Array[Float] argument is an Array.
#           AVOIDING NON-DIFFERENTIABLE POINTS IS THE WRITER'S JOB: at a relu
#           kink Enzyme returns a subgradient and the central difference
#           returns the average of the two arms, and both are right (R013
#           s3.3).  The gate stays "disagree = red" rather than growing a
#           heuristic nobody can audit.
#   export: overrides the C symbol stem.  Default: the method name.
#   hvp:    (E082, DRAFT decision record G9 -- awaiting user confirmation)
#           true adds a Hessian-vector-product export `spg_hvp_<stem>` built
#           by forward-over-reverse (E078 s5: __enzyme_fwddiff over the
#           reverse wrapper).  NOT a mode: the declaration stays :reverse and
#           G8's refusal of `mode: :forward` is untouched.  Requires wrt: to
#           be exactly one Array[Float] parameter.  Gated by G3H (vs a
#           central difference of the exact gradient), GDOT (returned
#           directional derivative vs grad.dir), GSYM (u.Hv == v.Hu) and G4H
#           (an identically-zero Hessian is accepted only when the gradient
#           is probe-independent -- a zero HVP and a broken HVP look alike).
#   jvp:    (E082, DRAFT G9) true adds `spg_jvp_<stem>`: the directional
#           derivative by pure forward mode on the primal.  Same wrt:
#           restriction.  Gated by G3F (vs finite difference) and GXF
#           (forward tangent vs reverse gradient -- the two AD modes are
#           checked against each other, not only against FD).
#
# The generated symbols are `sp_grad_<stem>` (gradient), `sp_gdval_<stem>`
# (the primal, under a private name so it can never clash with the program's
# own copy) and `sp_gdsig_<stem>` (the declaration's FNV-1a, so a stale
# .gen.rb against a fresh object file fails loud on the first call -- the same
# discipline tensor_def uses, E033 s4).
#
#     grad_def :dense_loss, wrt: [:w, :b], tol: 1e-6,
#              probe: [[[0.1, 0.2], [0.05], [1.0, 2.0], [0.5]]]
#     def dense_loss(w, b, x, t)
#       ...
#     end
#
# Calling this at run time does nothing at all -- it is a declaration, and the
# program that carries it is a perfectly ordinary Spinel program.
def grad_def(name, wrt: [], mode: :reverse, tol: 1.0e-6, probe: [],
             export: :"", hvp: false, jvp: false)
  0
end
