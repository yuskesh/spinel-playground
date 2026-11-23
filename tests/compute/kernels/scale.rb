gpu_buffer :v, :i32, 0
gpu_buffer :w, :i32, 1

def kernel__scale
  i = gpu_global_id
  gpu_store(:w, i, gpu_load(:v, i) * 3 + 1)
end
