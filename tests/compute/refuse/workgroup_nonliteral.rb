gpu_workgroup 2 + 2
gpu_buffer :x, :i32, 0
def kernel__a
  gpu_store(:x, 0, 1)
end
