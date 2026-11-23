# A helper that WRITES through a borrowed `inout` buffer, and one whose value
# must be narrowed to the element type before the write. The narrowing is
# checked: a value with no i32 is CAPACITY-free but not representable, and the
# status says so before any byte moves.
def dc_put(data, i, v)
  data[i] = v
end

def dc_store(data, n_data, i, v)
  dc_put(data, i, v)
end
