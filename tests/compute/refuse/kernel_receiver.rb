gpu_buffer :o, :i32, 0
def self.kernel__a
  gpu_store(:o, 0, 1)
end
