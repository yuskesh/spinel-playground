gpu_buffer :o, :i32, 0
def kernel__a
  3.times do |s|
    gpu_store(:o, s, 1)
  rescue
    gpu_store(:o, s, 2)
  end
end
