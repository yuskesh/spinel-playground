# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# Not a literal. This boundary resolves a constant at compile time and has no
# way to run an initialiser.

BOUND = 1 + 1

def dynamic_const(a, b)
  a + b + BOUND
end
