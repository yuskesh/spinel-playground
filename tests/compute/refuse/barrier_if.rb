gpu_workgroup 2
gpu_buffer :x, :i32, 0
def kernel__a
  if gpu_local_id == 0
    gpu_barrier
  end
  gpu_store(:x, 0, 1)
end
