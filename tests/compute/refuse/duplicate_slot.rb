gpu_buffer :x, :i32, 0
gpu_buffer :y, :i32, 0
def kernel__a
  gpu_store(:x, 0, 1)
end
