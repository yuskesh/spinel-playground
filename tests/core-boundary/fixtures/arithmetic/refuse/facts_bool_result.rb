# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# The facts say the parameters are integers. They do not say the RESULT is one,
# and this one is a comparison.

def bool_result(a, b)
  a < b
end
