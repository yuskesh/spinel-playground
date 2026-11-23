def tick(out)
  if out[0] > 0
    a = Core::Buffer.i64(2, 0)
    out[0] = a[0]
  end
  0
end
