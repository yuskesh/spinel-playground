gpu_buffer :o, :i32, 0
def kernel__a
  3.times { |s, t = 1| gpu_store(:o, s, t) }
end
