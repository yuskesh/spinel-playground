gpu_buffer :x, :f32, 0
def kernel__a
  gpu_store(:x, 0, gpu_load(:x, 0) % 2.0)
end
