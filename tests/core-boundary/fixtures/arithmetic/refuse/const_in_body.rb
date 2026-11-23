# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A definition inside a method body is not a top-level one. Ruby itself refuses
# this -- `dynamic constant assignment` is a parse error, not something the
# analysis sees -- so the refusal arrives as an unanalysable root. Kept because
# that is worth recording: there is no such thing as a method-local constant to
# have an opinion about.

def const_in_body(a, b)
  BOUND = 7
  a + b + BOUND
end
