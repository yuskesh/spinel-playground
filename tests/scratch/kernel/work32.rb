# Decision 0045: the 32-bit twin of work.rb, for the thumbv8m build: a
# buffer's element name is the body's width, so work.rb's Core::Buffer.i64
# is refused at 32 bits (run.sh checks that too). Otherwise as work.rb.

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
  a = Core::Buffer.i32(n, 0)
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
