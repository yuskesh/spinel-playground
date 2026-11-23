gpu_buffer :x, :f32, 0
def kernel__a
  gpu_store(:x, gpu_global_id, gpu_load(:x, 0) + 1)
end
