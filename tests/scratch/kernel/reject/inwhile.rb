def tick(out)
  i = 0
  while i < 2
    a = Core::Buffer.i64(2, 0)
    out[0] = a[0]
    i += 1
  end
  0
end
