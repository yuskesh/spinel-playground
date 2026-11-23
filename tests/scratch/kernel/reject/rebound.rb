def tick(out)
  a = Core::Buffer.i64(2, 0)
  a = Core::Buffer.i64(3, 0)
  out[0] = a[0]
  0
end
