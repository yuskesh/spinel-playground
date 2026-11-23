# Control: the same count with no atomic must lose updates under contention.
gpu_workgroup 64
gpu_buffer :x, :i32, 0
gpu_buffer :h, :i32, 1

def kernel__nonatomic
  gpu_store(:h, 0, gpu_load(:h, 0) + gpu_load(:x, gpu_global_id))
end
