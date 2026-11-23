gpu_workgroup 2
gpu_buffer :x, :i32, 0
def kernel__a
  gpu_load(:x, 0).times do
    gpu_barrier
  end
end
