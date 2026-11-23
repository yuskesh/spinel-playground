# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A `while` falls through and has no value: it is nil in Ruby, and nil is not
# in this subset. That is NOT the same as a branch that never arrives, and
# treating the two alike let this take the 7.

def while_value(a, b)
  if b > 0
    while b > 0
      b = b - 1
    end
  else
    7
  end
end
