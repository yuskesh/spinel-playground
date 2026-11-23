gpu_workgroup 4
gpu_buffer :x, :f32, 0
gpu_buffer :partial, :f32, 1
gpu_shared :acc, :f32, 4

def kernel__reduce
  i = gpu_global_id
  l = gpu_local_id
  gpu_shared_store(:acc, l, gpu_load(:x, i))
  gpu_barrier
  2.times do |s|
    stride = 4 >> (s + 1)
    if l < stride
      gpu_shared_store(:acc, l, gpu_shared_load(:acc, l) + gpu_shared_load(:acc, l + stride))
    end
    gpu_barrier
  end
  if l == 0
    gpu_store(:partial, gpu_group_id, gpu_shared_load(:acc, 0))
  end
end
