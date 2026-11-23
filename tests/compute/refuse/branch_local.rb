gpu_buffer :x, :i32, 0
def kernel__a
  if gpu_load(:x, 0) < 1
    v = 1
  end
  gpu_store(:x, 0, v)
end
