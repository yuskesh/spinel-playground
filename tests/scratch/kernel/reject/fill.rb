def tick(out)
  k = 3
  a = Core::Buffer.i64(2, k)
  out[0] = a[0]
  0
end
