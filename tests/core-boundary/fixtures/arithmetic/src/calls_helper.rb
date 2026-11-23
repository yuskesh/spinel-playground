# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file, plus any helpers it calls. There is no caller and no
# evidence call: the contract declares each parameter's domain, and the checker
# derives the rest of the closure from those facts and validates every use
# against them.
# A direct callee that can fail. The caller has to look at the callee's status
# and hand it on unchanged, or a failure inside the helper reads as a success
# with whatever was in the result slot.

def doubled(a)
  a + a
end

def calls_helper(a, b)
  doubled(a) + b
end
