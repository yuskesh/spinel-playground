# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# The same conflict as facts_join_conflict with the arms swapped: the integer
# binding is in the else arm and the boolean in the then arm. A derivation that
# depended on the order it visited them would take one of these and not the
# other.

def branch_order(a, b)
  if b == 0
    x = a < b
  else
    x = 1
  end
  x + 1
end
