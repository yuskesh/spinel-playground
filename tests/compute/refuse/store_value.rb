gpu_buffer :x, :i32, 0
def kernel__a
  v = gpu_store(:x, 0, 1)
end
