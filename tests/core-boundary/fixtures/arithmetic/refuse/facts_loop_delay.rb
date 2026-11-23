# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A type mismatch introduced at the END of the loop body and carried backwards
# one variable per iteration, so it reaches `r` only after four passes. Every
# local is then reassigned an integer AFTER the loop, so a check that looked
# only at the final environment would see nothing wrong.

def loop_delay(a, b, c, d, n)
  r = a + 1
  while n > 0
    r = a + 1
    a = b
    b = c
    c = d
    d = n > 0
    n = n - 1
  end
  a = 1
  b = 1
  c = 1
  d = 1
  r = 1
  r
end
