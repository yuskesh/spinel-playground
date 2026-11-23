# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file, plus any helpers it calls, and no caller anywhere:
# the contract declares each parameter's domain and the checker derives the
# rest of the closure from those facts.

# Early return, which decision 0007 admits and the checker did not: a `return`
# anywhere in a checked closure was refused as an unsupported node.

def early_return(a, b)
  if b == 0
    return 1
  else
    return a + b
  end
end
