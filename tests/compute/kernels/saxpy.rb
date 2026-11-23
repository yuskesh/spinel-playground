gpu_buffer :x, :f32, 0
gpu_buffer :y, :f32, 1
gpu_buffer :out, :f32, 2

def kernel__saxpy
  i = gpu_global_id
  gpu_store(:out, i, 2.5 * gpu_load(:x, i) + gpu_load(:y, i))
end
