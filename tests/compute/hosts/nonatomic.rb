n = 262144
h = IO::Buffer.new(n * 4)
xs = IO::Buffer.new(n * 4)
n.times { |i| xs.set_value(:s32, i * 4, 1) }
Nonatomic.open(n)
Nonatomic.x_write(xs)
Nonatomic.dispatch(n)
Nonatomic.h_read(h)
Nonatomic.close
check("no update was lost", read_i32(h, 0), n)
