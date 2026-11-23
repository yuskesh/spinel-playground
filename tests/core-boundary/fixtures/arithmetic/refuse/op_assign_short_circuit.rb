# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# `||=` and `&&=` arrive here as operator-assignments whose operator is `||` or
# `&&`. They short-circuit, which changes WHEN the assignment happens, so they
# are a different statement and stay outside the closed set.

def short_circuit(a, b)
  a ||= 1
  a + b
end
