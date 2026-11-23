n = 8
partial = IO::Buffer.new(n * 4)
Reduce.open(n)
Reduce.x_write(f32s([1.0, 2.0, 3.0, 4.0, 10.0, 20.0, 30.0, 40.0]))
Reduce.dispatch(n)
Reduce.partial_read(partial)
Reduce.close
check("reduce group 0", read_f32(partial, 0), 10.0)
check("reduce group 1", read_f32(partial, 1), 100.0)
