gpu_buffer :x, :float, 0
def kernel__a
  gpu_store(:x, gpu_global_id, 1.0)
end
