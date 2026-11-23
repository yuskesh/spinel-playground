def tick(out)
  a = Core::Buffer.i64(2, 0)
  b = a
  out[0] = b[0]
  0
end
