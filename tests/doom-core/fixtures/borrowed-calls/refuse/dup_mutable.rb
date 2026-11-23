def dc_pair(x, y, i)
  x[i] = y[i]
end

def dup_mutable(data, n_data, i)
  dc_pair(data, data, i)
end
