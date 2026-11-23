# Decision 0041 stage 2, the kernel's own fixture: work(n) makes n zeros,
# writes a[0] = 5 and a[1] += 2, adds 3 to each element in fill (a while
# over b.size) and answers sum2(a) (a b.each block) + a.size. tick runs
# work(4); tick2 runs work(inp[0]), the size the caller chooses.

def fill(b, k)
  i = 0
  while i < b.size
    b[i] = b[i] + k
    i += 1
  end
  0
end

def sum2(b)
  t = 0
  b.each { |x| t += x }
  t
end

def work(n)
  a = Core::Buffer.i64(n, 0)
  a[0] = 5
  a[1] += 2
  fill(a, 3)
  sum2(a) + a.size
end

def tick(out)
  out[0] = work(4)
  0
end

def tick2(inp, out)
  out[0] = work(inp[0])
  0
end
