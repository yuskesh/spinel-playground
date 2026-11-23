# The positive control beside `refuse/dup_mutable.rb`: the SAME read-only
# buffer at two argument positions is admitted. Reading the same bytes twice
# is reading the same bytes twice; what the alias rule refuses is a WRITE
# through one of two names for one storage.
def dc_sum(x, y, i)
  x[i] + y[i]
end

def dc_twice_ro(data, n_data, i)
  dc_sum(data, data, i)
end
