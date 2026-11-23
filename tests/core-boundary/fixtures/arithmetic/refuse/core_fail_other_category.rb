# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# The other internal categories belong to failures the compiler establishes.

def other_category(a, b)
  if b == 0
    core_fail(:bounds)
  else
    a + b
  end
end
