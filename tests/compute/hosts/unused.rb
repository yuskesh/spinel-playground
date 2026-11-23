n = 4
y = IO::Buffer.new(n * 4)
Unused.open(n)
Unused.dispatch(n)
Unused.y_read(y)
Unused.close
n.times { |i| check("unused #{i}", read_f32(y, i), 1.5) }
