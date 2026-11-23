def dc_put(data, i)
  data[i] = 7
end

def readonly_write(data, n_data, i)
  dc_put(data, i)
end
