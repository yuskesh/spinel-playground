# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file. There is no caller and no evidence call: the
# contract declares each parameter's domain, and the checker derives the rest of
# the closure from those facts.

# `x op= e` is `x = x op e` written once, and must mean that for every operator
# the mode admits -- not only the five the lowering started with. The checker
# admitted the shifts and the bitwise operators here while the lowering took
# `+ - * / %` alone, so one statement had two answers.

def op_assign(a, b)
  a <<= 2
  a &= 255
  a |= 1
  a ^= 2
  a >>= 1
  a + b
end
