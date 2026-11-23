# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# Three returns, int then bool then int. An earlier derivation used one empty
# value for both "nothing known yet" and "two types met here", so the middle
# one erased the conflict and the third revived int.

def three_returns(a, b)
  if a > 0
    return 1
  else
    if b > 0
      return a > b
    else
      return 2
    end
  end
end
