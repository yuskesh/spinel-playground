# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# One helper reached at two different types has no one signature. The derivation
# empties the slot rather than picking a winner, and the call site is refused.

def echo(x)
  x
end

def callee_conflict(a, b)
  echo(a) + echo(a < b)
end
