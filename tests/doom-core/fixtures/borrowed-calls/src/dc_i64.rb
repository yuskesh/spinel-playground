# An i64 element, where INT64_MIN is an ordinary value and not a sentinel.
def dc_at64(data, i)
  data[i]
end

def dc_i64(data, n_data, i)
  dc_at64(data, i)
end
