# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A user definition does not shadow the intrinsic into an ordinary call: the
# two cannot both be meant, so the conflict is refused rather than resolved.

def core_fail(category)
  category
end

def user_def(a, b)
  if b == 0
    core_fail(:capacity)
  else
    a + b
  end
end
