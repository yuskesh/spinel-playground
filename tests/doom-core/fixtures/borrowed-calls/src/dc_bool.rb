# An internal helper whose result is a BOOLEAN, consumed by a branch. The
# contract exports an integer, so the boolean never crosses the boundary: it
# is a value this closure computes and consumes.
def dc_inside(n, i)
  i < n
end

def dc_bool(data, n_data, i)
  dc_inside(n_data, i) ? dc_at(data, i) : -1
end

def dc_at(data, i)
  data[i]
end
