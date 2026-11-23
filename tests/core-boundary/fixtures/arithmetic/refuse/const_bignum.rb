# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# One past INT64_MAX. The producer saturates `value` to INT64_MAX and keeps the
# exact text in `bigval`, so reading `value` alone would accept this as
# 9223372036854775807.

BIG = 9223372036854775808

def const_bignum(a, b)
  a + b + BIG
end
