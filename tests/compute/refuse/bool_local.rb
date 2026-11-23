gpu_buffer :x, :i32, 0
def kernel__a
  c = gpu_load(:x, 0) < 1
end
