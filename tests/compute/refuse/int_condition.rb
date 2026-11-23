gpu_buffer :x, :i32, 0
def kernel__a
  if gpu_load(:x, 0)
    gpu_store(:x, 0, 1)
  end
end
