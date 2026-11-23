# Parameter names that are C typedefs in any unit including <stdint.h>.  Ruby
# has no opinion about them.  A generated C prototype that used them as its own
# parameter identifiers would shadow those typedefs for the rest of the
# parameter list, and the parameters that follow would not parse.
def blend(uint8_t, src, n_src, int64_t)
  i = 0
  total = uint8_t + int64_t
  while i < n_src
    total = total + src[i]
    i = i + 1
  end
  total
end
