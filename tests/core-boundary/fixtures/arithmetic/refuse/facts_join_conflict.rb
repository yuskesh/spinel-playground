# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# The two arms bind `x` to different types, so nothing survives the join and
# the use below it is underivable. Painting `poly` with `int` would admit this.

def join_conflict(a, b)
  if b == 0
    x = 1
  else
    x = a < b
  end
  x + 1
end
