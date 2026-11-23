# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A `core_fail` that succeeded would be a contradiction.

def fail_ok(a, b)
  if b == 0
    core_fail(:ok)
  else
    a + b
  end
end
