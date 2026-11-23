# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# NOT a refusal: the producer-typed path, kept beside the derived one. A source
# that does have a caller must still be accepted, and this is what says so.

def with_evidence(a, b)
  a + b
end

with_evidence(1, 2)
