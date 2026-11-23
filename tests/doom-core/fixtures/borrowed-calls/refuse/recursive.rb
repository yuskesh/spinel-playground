def dc_walk(data, i)
  i < 0 ? 0 : dc_walk(data, i - 1)
end

def recursive(data, n_data, i)
  dc_walk(data, i)
end
