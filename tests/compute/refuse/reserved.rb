gpu_buffer :x, :i32, 0
def __sp_gpu_load_x(i)
  1
end
def kernel__a
  gpu_store(:x, 0, 1)
end
