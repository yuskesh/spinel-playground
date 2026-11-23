# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# Two assignments. A constant here names one value, and resolving to whichever
# one ran last would be running the program to compile it.

BOUND = 1
BOUND = 2

def redefined(a, b)
  a + b + BOUND
end
