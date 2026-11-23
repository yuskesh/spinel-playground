# E082 -- the reject corpus for the rules + forward vocabulary.  Every method
# runs as ordinary Ruby (the four puts at the bottom print), and every
# grad_def below is REFUSED with the obstacle named:
#
#   myst_loss  norule     SPGR surface, but the ledger registers no rule --
#                         the compile-time refusal that replaces both of
#                         Enzyme's failure shapes (a hard error deep in opt
#                         for a float extern, R013 O2 silence for an int one)
#   lutj       norulefwd  jvp: over a primitive with no FORWARD rule
#                         (Enzyme v0.0.290 cannot resolve a forward
#                         registration at const-arg call sites,
#                         EnzymeLogic.cpp:4903 -- measured in E082)
#   hsca       fwd1       hvp: with a scalar wrt (the initial forward surface
#                         is exactly one Array[Float], draft record G9)
#   rbclamp    O5         Ruby's own Float#clamp -- sp_float_clamp_ck ->
#                         sp_float_to_s -> sp_str_alloc with no raise on the
#                         path.  THE MOTIVATION ROW: this is what SPGR's
#                         spg_clamp01 exists to replace
require_relative "spinel/grad"
require_relative "spinel/grad_rules"

grad_def :myst_loss, wrt: [:x], probe: [[[0.3, 0.6], 2]]
def myst_loss(x, n)
  s = 0.0
  i = 0
  while i < n
    s += SPGR.spg_mystery(x[i])
    i += 1
  end
  s
end

grad_def :lutj, wrt: [:x], jvp: true,
         probe: [[[0.5, 1.5], 2, [0.0, 1.0, 4.0], 3]]
def lutj(x, n, tab, m)
  s = 0.0
  i = 0
  while i < n
    s += SPGR.spg_lut1(tab, m, x[i])
    i += 1
  end
  s
end

grad_def :hsca, wrt: [:a], hvp: true, probe: [[2.0, [1.0, 2.0], 2]]
def hsca(a, x, n)
  s = 0.0
  i = 0
  while i < n
    s += a * x[i] * x[i]
    i += 1
  end
  s
end

grad_def :rbclamp, wrt: [:x], probe: [[[0.3, 0.6], 2]]
def rbclamp(x, n)
  s = 0.0
  i = 0
  while i < n
    v = x[i].clamp(0.0, 1.0)
    s += v * v
    i += 1
  end
  s
end

puts myst_loss([0.3, 0.6], 2)
puts lutj([0.5, 1.5], 2, [0.0, 1.0, 4.0], 3)
puts hsca(2.0, [1.0, 2.0], 2)
puts rbclamp([0.3, 0.6], 2)
