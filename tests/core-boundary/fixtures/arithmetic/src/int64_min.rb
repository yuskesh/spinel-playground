# Arithmetic reference kernel for decision 0007 task 2.
#
# One definition per file, plus any helpers it calls, and no caller anywhere:
# the contract declares each parameter's domain and the checker derives the
# rest of the closure from those facts.

# Decision 0007: the native CORE ABI retains the entire signed i64 domain and
# native entry values have no nil sentinel, so INT64_MIN is an ordinary value
# here. Upstream a07741ff1 removed the hosted nil reservation. The ordinary
# scalar checker still refuses this uncalled file: its parameters have no
# inferred integer evidence, unlike the explicitly declared boundary.
#
# Both spellings, because they are different nodes to the checker: a named
# constant resolved at compile time, and the literal in the expression itself.

MIN_I64 = -9223372036854775808

def int64_min(a, b)
  if a > 0
    MIN_I64
  else
    -9223372036854775808 + b
  end
end
