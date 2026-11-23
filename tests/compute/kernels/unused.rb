# A buffer the kernel never touches must not move the buffers after it.
gpu_buffer :x, :f32, 0
gpu_buffer :y, :f32, 1

def kernel__unused
  gpu_store(:y, gpu_global_id, 1.5)
end
