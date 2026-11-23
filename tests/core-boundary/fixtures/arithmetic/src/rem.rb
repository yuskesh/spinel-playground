# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file. There is no caller and no evidence call: the
# contract declares each parameter's domain, and the checker derives the rest of
# the closure from those facts and validates every use against them.
# Divisor-signed remainder. 7 % -2 is -1 here and 1 in C.

def rem(a, b)
  a % b
end
