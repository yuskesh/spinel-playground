# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A computed argument names nothing at compile time.

def dynamic(a, b)
  c = :capacity
  if b == 0
    core_fail(c)
  else
    a + b
  end
end
