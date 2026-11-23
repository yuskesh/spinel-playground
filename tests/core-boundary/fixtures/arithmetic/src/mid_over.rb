# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file. There is no caller and no evidence call: the
# contract declares each parameter's domain, and the checker derives the rest of
# the closure from those facts and validates every use against them.
# The INTERMEDIATE overflows and the final value does not: (INT64_MAX + 1) - 1
# is INT64_MAX in Ruby. A check applied only to the returned value admits this.

def mid_over(a, b)
  (a + b) - b
end
