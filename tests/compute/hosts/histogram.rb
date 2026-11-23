n = 8
h = IO::Buffer.new(n * 4)
Histogram.open(n)
Histogram.x_write(i32s([0, 1, 2, 3, -1, -2, 5, 7]))
Histogram.h_write(i32s([0, 0, 0, 0, 0, 0, 0, 0]))
Histogram.dispatch(n)
Histogram.h_read(h)
Histogram.close
want = [1, 2, 2, 3]
4.times { |i| check("histogram #{i}", read_i32(h, i), want[i]) }
