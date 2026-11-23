gpu_buffer :o, :i32, 0
def kernel__a
  3.times(2) { |s| gpu_store(:o, s, 1) }
end
