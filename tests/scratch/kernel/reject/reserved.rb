module Core
  Buffer = 17
end

def tick(out)
  a = Core::Buffer.i64(2, 7)
  out[0] = a[1]
  0
end
