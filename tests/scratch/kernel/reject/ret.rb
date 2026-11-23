def mk(n)
  a = Core::Buffer.i64(n, 0)
  a
end
def tick(out)
  b = mk(2)
  out[0] = b[0]
  0
end
