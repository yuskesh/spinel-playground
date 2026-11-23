# The borrow travels two calls deep. `dc_inner` is reached only through
# `dc_outer`, so its parameter is an address by derivation twice over.
def dc_inner(data, i)
  data[i]
end

def dc_outer(data, i)
  dc_inner(data, i)
end

def dc_nested(data, n_data, i)
  dc_outer(data, i)
end
