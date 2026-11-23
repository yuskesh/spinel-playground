n = 4
w = IO::Buffer.new(n * 4)
w.set_value(:s32, 0, 77)
Scale.open(n)
Scale.w_read(w)
Scale.close
n.times { |i| check("open zeroes buffer #{i}", read_i32(w, i), 0) }
