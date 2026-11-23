# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file, plus any helpers it calls. There is no caller and no
# evidence call: the contract declares each parameter's domain, and the checker
# derives the rest of the closure from those facts and validates every use
# against them.
# `core_fail(:<category>)` returns one of the boundary's own failure statuses.
# It is a return, so it lives where a return lives.

def capacity_when_zero(a, b)
  if b == 0
    core_fail(:capacity)
  else
    a + b
  end
end
