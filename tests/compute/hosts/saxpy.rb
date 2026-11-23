n = 4
out = IO::Buffer.new(n * 4)
Saxpy.open(n)
Saxpy.x_write(f32s([1.0, 2.0, 3.0, 4.0]))
Saxpy.y_write(f32s([0.5, 0.5, 0.5, 0.5]))
Saxpy.dispatch(n)
Saxpy.out_read(out)
Saxpy.close
want = [3.0, 5.5, 8.0, 10.5]
n.times { |i| check("saxpy #{i}", read_f32(out, i), want[i]) }
