# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file, plus any helpers it calls, and no caller anywhere:
# the contract declares each parameter's domain and the checker derives the
# rest of the closure from those facts.

# A named literal scalar constant: a single unconditional top-level assignment
# of an integer literal, resolved at compile time and read like any other
# integer. `a * 2 + 3` does not exercise this -- it has no name in it.

SCALE = 7

def named_const(a, b)
  a * SCALE + b
end
