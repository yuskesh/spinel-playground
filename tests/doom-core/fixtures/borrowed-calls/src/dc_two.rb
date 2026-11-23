# One helper, two calls, two different buffers with two different counts.
# Each call carries its own descriptor, so the helper's bound is whichever
# buffer that call passed and never the other one.
def dc_at(data, i)
  data[i]
end

def dc_two(a, n_a, b, n_b, i)
  dc_at(a, i) + dc_at(b, i)
end
