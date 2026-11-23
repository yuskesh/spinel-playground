Core = 17

def tick(out)
  a = Core::Buffer.i64(2, 7)
  out[0] = a[1]
  0
end
