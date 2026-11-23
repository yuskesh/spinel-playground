# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A conditional definition is not an unconditional top-level assignment, and
# which branch ran is a run-time fact.

if 1 > 0
  BOUND = 1
else
  BOUND = 2
end

def conditional_const(a, b)
  a + b + BOUND
end
