# subset-entry: node ConstantReadNode
# The first construct of the subset refusal tables that the walk meets in f is
# this entry's; tests/subset/reasons.sh requires spinel-fs-emit to refuse f
# with this entry's reason.
require_relative "spinel/freestanding"
K = 3
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  y = K
  x
end
