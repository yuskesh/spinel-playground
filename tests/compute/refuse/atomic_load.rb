gpu_buffer :x, :atomic, 0
def kernel__a
  v = gpu_load(:x, 0)
end
