# subset-entry: call **
# The first construct of the subset refusal tables that the walk meets in f is
# this entry's; tests/subset/reasons.sh requires spinel-fs-emit to refuse f
# with this entry's reason. (`**` on two Integers is a power, decision 0042,
# so the receiver here is a buffer.)
require_relative "spinel/freestanding"
freestanding_def :f, params: [[:i32_buf, :inout], :len], returns: :i32
def f(b, n)
  y = b ** 2
  n
end
