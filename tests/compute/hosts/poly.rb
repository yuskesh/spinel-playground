n = 4
y = IO::Buffer.new(n * 4)
Poly.open(n)
Poly.x_write(f32s([0.0, 1.0, 2.0, 0.5]))
Poly.dispatch(n)
Poly.y_read(y)
Poly.close
want = [8.0, 36.0, 502.0, 14.0078125]
n.times do |i|
  # sqrt may differ by the host's rounding: the tolerance is 1e-3, set by hand.
  diff = read_f32(y, i) - want[i]
  diff = 0.0 - diff if diff < 0.0
  check("poly #{i}", diff < 0.001, true)
end
