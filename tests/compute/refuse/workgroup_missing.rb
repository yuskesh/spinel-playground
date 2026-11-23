gpu_buffer :x, :i32, 0
def kernel__a
  gpu_store(:x, gpu_local_id, 1)
end
