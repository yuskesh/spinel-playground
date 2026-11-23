# subset-entry: node InterpolatedStringNode
# The first construct of the subset refusal tables that the walk meets in f is
# this entry's; tests/subset/reasons.sh requires spinel-fs-emit to refuse f
# with this entry's reason.
require_relative "spinel/freestanding"
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  s = "a#{x}"
  x
end
