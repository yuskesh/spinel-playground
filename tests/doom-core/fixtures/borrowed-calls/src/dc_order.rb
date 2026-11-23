# EVALUATION ORDER IN `buf[i] op= rhs`, where the right-hand side WRITES the
# same element. Ruby expands this to `buf[i] = buf[i] op rhs` and evaluates
# the element READ FIRST, so the left operand is the value the element had
# BEFORE the call -- not the one the call leaves behind.
#
# This was a real miscompilation, found in Mac review of 33da4d9: the lowering
# emitted the load AFTER the right-hand side, so `buf[0] += dc_rhs(buf)` with
# `dc_rhs` storing 6 and returning 5 gave 11 where CRuby gives 6, with status
# OK and no diagnostic. A wrong answer with an OK status is the worst shape a
# defect can take, because nothing downstream has a reason to look.
#
# The fixture is a call, not an expression, because only a call can write the
# element between the read and the store.
def dc_rhs(buf, n_buf)
  buf[0] = 6
  5
end

def dc_order(buf, n_buf)
  buf[0] += dc_rhs(buf, n_buf)
  buf[0]
end
