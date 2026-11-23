# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file. There is no caller and no evidence call: the
# contract declares each parameter's domain, and the checker derives the rest of
# the closure from those facts and validates every use against them.
# Decision 0042 stage 3: the exact power, or ARITHMETIC where it is past the
# width or the exponent is negative. (It was refused outright before, since
# Ruby's answer there is a Bignum or a Rational.)

def power(a, b)
  a**b
end
