gpu_buffer :x, :i32, 0
gpu_buffer :h, :atomic, 1

def kernel__histogram
  v = gpu_load(:x, gpu_global_id)
  gpu_atomic_add(:h, v % 4, 1)
end
