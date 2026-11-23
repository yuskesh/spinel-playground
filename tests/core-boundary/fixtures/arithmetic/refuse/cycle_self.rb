# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# Direct recursion. The closure is not statically bounded, and the derivation
# must terminate on it as well as the checker refusing it.

def down(n)
  if n > 0
    down(n - 1)
  else
    0
  end
end

def self_cycle(a, b)
  down(a) + b
end
