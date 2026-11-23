gpu_buffer :o, :i32, 0
def kernel__a
  gpu_store(:o, 0, 1)
rescue
  gpu_store(:o, 0, 2)
end
