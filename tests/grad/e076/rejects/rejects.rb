# E076 -- the reject corpus.  One file, one declaration per obstacle.
#
# R013 s3.3 catalogued seven obstacles between a Ruby method and its gradient.
# This file is the executable version of that table: every method below is
# ORDINARY RUBY that runs (the `puts` block at the bottom proves it), and every
# `grad_def` on it is REFUSED, with the obstacle named -- except O6, which the
# pin baddd25a9 removed (below).
#
# The point is not that these are unusual programs.  O6 in particular is the
# shape of every damped recurrence anyone would write, and O2 is what happens
# when a perfectly reasonable integer scorer meets a gradient.  Enzyme's answer
# to O2 is an empty adjoint AND NO DIAGNOSTIC, so what is being demonstrated
# here is the difference between "refused with a reason" and "returned garbage".
require_relative "spinel/grad"

# ---- O2: an Integer primal.  THE mine (R013 s3.3 O2). ---------------------
# Enzyme builds `define internal void @diffesp_oint(i64, i64)` -- an adjoint
# that returns nothing -- and says nothing at all.  The C side's variadic
# `double __enzyme_autodiff(...)` is not type-checked, so the caller reads the
# return register: R013 measured 4.146198773418936e-314, five times in a row.
grad_def :oint, wrt: [:x], probe: [[3.0, 4.0]]
def oint(x, a)
  a * x * x
end

# ---- O2b: Float return, but the ACTIVE argument is an Integer -------------
# The primal has floating point in it, so the adjoint is not empty -- but the
# derivative with respect to an integer argument still does not exist.
grad_def :oint_arg, wrt: [:n], probe: [[2.0, 3.0]]
def oint_arg(x, n)
  x * n.to_f
end

# ---- O4: a widened local (TY_POLY) ---------------------------------------
# Enzyme's TypeAnalysis reads the sp_RbVal union as Pointer AND Float@double
# at once and gives up: "Enzyme: <analysis>".
grad_def :opoly, wrt: [:x], probe: [[2.0]]
def opoly(x)
  t = x > 0.0 ? x : 1
  t * x
end

# ---- O6: `v = v * k` inside a `while` -- the bigint promotion -------------
# THE obstacle that matters, because this is what damping, friction, geometric
# series and power iteration all look like.  analyze_pass.c's loop-growth
# bigint promotion runs BEFORE the inference fixpoint, catches `v` while it is
# still TY_UNKNOWN, and `bigint | float = TY_POLY`.  The workaround is one line
# and is measured next door in `accepts.rb`.
# Since the pin baddd25a9 (upstream bd53f5938, docs/provenance.md) the
# promotion asks the local's writes first, `v` infers Float, and gradgen
# ACCEPTS odecay: expect.tsv marks it `accepted` and run.sh checks its G3.
grad_def :odecay, wrt: [:v0], probe: [[1.0, 8.0]]
def odecay(v0, n)
  v = v0
  i = 0
  while i < n
    v = v * 0.9
    i += 1
  end
  v
end

# ---- O7: a toplevel constant ----------------------------------------------
# `K` becomes `static mrb_float cst_K = 0;` that `main` assigns.  The
# differentiation build never runs `main`, so the constant reads 0 -- and the
# finite-difference gate CANNOT SEE IT, because f == 0 and df == 0 agree.  This
# is the one obstacle G3 is structurally blind to, which is why G1 refuses the
# constant read outright.
K = 2.5
grad_def :oconst, wrt: [:x], probe: [[2.0]]
def oconst(x)
  x * K
end

# ---- O5: the method allocates ---------------------------------------------
# An Array literal is an sp_gc_alloc.  Allocation means collection is possible,
# collection means the GC roots are load-bearing, and Enzyme refuses any
# function that writes @sp_gc_roots.  Note the ORDER: gradgen does not "turn
# roots off and hope", it asks spinel-rtcheck first and refuses when the proof
# fails (E017, R013 s6.1).
grad_def :oalloc, wrt: [:x], probe: [[2.0]]
def oalloc(x)
  a = [x, x * 2.0]
  a[0] + a[1]
end

# ---- outside the subset: a String ------------------------------------------
grad_def :ostr, wrt: [:x], probe: [[2.0]]
def ostr(x)
  s = "abcd"
  x * s.length
end

# ---- outside the subset: a Hash --------------------------------------------
grad_def :ohash, wrt: [:x], probe: [[2.0]]
def ohash(x)
  h = { 1 => 2.0 }
  x * h[1]
end

# ---- declaration errors ----------------------------------------------------
# wrt: names something that is not a parameter.
grad_def :owrt, wrt: [:zzz], probe: [[2.0]]
def owrt(x)
  x * x
end

# forward mode does not exist yet (P007 Phase 4).  Refusing beats silently
# doing reverse and calling it forward.
grad_def :ofwd, wrt: [:x], mode: :forward, probe: [[2.0]]
def ofwd(x)
  x * x
end

# no probe: -- a declaration G3 and G4 cannot evaluate is not a declaration.
grad_def :onoprobe, wrt: [:x]
def onoprobe(x)
  x * x
end

puts oint(3, 4)
puts oint_arg(2.0, 3)
puts opoly(2.0)
puts odecay(1.0, 8)
puts oconst(2.0)
puts oalloc(2.0)
puts ostr(2.0)
puts ohash(2.0)
puts owrt(2.0)
puts ofwd(2.0)
puts onoprobe(2.0)
