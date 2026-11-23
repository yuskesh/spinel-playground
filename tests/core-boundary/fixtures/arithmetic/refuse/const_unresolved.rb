# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# Nothing in this source assigns it.

def unresolved_const(a, b)
  a + b + MISSING
end
