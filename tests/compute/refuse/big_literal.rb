gpu_buffer :x, :i32, 0
def kernel__a
  gpu_store(:x, 0, 2147483648)
end
