# E016 -- end-to-end regression for the R3 (callee-roots) soundness hole that
# E015 found and fixed during the PoC without leaving a test behind.
#
# THE SHAPE.  `combine(n, churn(0))` is emitted by Spinel's codegen verbatim as
#
#     return sp_combine(lv_n, sp_churn(0LL));
#
# and clang evaluates the arguments left to right, so the frontend IR is
#
#     %v = load ptr, ptr %lv_n          ; the rooted local
#     %k = call i64 @sp_churn(i64 0)    ; may-GC-and-return, NOT exempt
#     %r = call i64 @sp_combine(ptr %v, i64 %k)   ; may-GC, roots its param 0
#
# R3 exempts `sp_combine` from vetoing the elision of lv_n's root, because the
# callee roots that parameter before it can collect.  The exemption must not
# ALSO shorten lv_n's live range: if it does, the range ends at the load, the
# collection inside sp_churn is no longer "live across", the root is elided,
# and lv_n is unrooted across 300 real collections.
#
# WHY THIS PROGRAM AND NOT A SIMPLER ONE.  `churn` allocates same-size Node
# objects, so the freed lv_n slot is RECYCLED and n.sum reads the new tenant's
# fields.  Without the recycling the dangling read usually still returns 7 and
# the test is silent.  Measured (pass built from the pre-fix source):
#
#     no stress          : 7        <- the bug is invisible
#     SPINEL_GC_STRESS=1 : 990000   <- 900000 + 90000, the recycled Node
#
# so this test only bites in stress mode.  That is the whole point of E016.

class Node
  def initialize(a, b)
    @a = a
    @b = b
  end

  def sum
    @a + @b
  end
end

# May-GC and returns, and returns an Integer -- which is why codegen leaves the
# call inline in the argument list instead of hoisting it into a rooted temp.
def churn(i)
  j = 0
  s = 0
  while j < 300
    s += Node.new(900000, 90000).sum
    j += 1
  end
  s - s + i
end

# Roots its reference parameter in the entry block before it can collect (the
# invariant R3 checks for), and really does collect afterwards.
def combine(x, k)
  t = "z#{k}"
  x.sum + k + t.length - t.length
end

def run
  n = Node.new(3, 4)
  combine(n, churn(0))
end

puts run
