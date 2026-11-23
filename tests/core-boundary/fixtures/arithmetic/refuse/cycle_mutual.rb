# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# The same through two methods, which a check that only looked for a call to
# itself would miss.

def ping(n)
  if n > 0
    pong(n - 1)
  else
    0
  end
end

def pong(n)
  ping(n)
end

def mutual_cycle(a, b)
  ping(a) + b
end
