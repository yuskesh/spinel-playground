def tick(out)
  3.times { |i| a = Core::Buffer.i64(2, 0); out[0] = a[0] + i }
  0
end
