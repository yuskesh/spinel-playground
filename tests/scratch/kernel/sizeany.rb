# Decision 0041 stage 2: a count that rises and then falls as a.size grows,
# s * (40 - s), takes no single worst value at either end of [0, 31]; the
# report says the work is unknown rather than pick one.
def tick(out)
  n = out[0]
  a = Core::Buffer.i64(n, 0)
  s = a.size
  m = s * (40 - s)
  i = 0
  while i < m
    i += 1
  end
  out[0] = i
  0
end
