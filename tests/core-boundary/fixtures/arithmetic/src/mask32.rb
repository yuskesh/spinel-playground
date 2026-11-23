# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file. There is no caller and no evidence call: the
# contract declares each parameter's domain, and the checker derives the rest of
# the closure from those facts and validates every use against them.
# An explicit mask is that operation, not a global wrap switch: the result is
# the value of the low 32 bits, in the i64 domain.

def mask32(a)
  a & 0xffffffff
end
