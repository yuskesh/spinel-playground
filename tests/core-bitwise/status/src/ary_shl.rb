# An Array local with `<<`: an append, refused before any shift.
def ary_shl(a, n)
  x = [a]
  x << n
  n
end
