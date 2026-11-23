# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# The same saturation, in an expression rather than a constant. One below
# INT64_MIN, so the saturated value is INT64_MIN -- which IS admissible on this
# route, and would be the wrong answer.

def literal_bignum(a, b)
  a + b + -9223372036854775809
end
