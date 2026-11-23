def tick(out)
  a = Core::Buffer.i64(2); a.push(1)
  out[0] = a[0]
  0
end
