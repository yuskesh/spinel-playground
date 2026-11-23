# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# Five helpers deep, and the last one returns a comparison. The result has to
# travel back up the chain before the caller's `+` can be judged.

def link5(x)
  x > 0
end

def link4(x)
  link5(x)
end

def link3(x)
  link4(x)
end

def link2(x)
  link3(x)
end

def link1(x)
  link2(x)
end

def chain(a, b)
  link1(a) + b
end
