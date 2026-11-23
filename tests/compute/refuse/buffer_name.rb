gpu_buffer :"a-b", :i32, 0
def kernel__a
  gpu_store(:"a-b", 0, 1)
end
