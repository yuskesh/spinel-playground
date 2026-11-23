# Decision 0041 stage 2: every size a constant, so the report composes the
# worst path: outer's 4 + 2 elements under inner's 3, 9 elements (72
# bytes at 8 bytes each on a 64-bit host).

def inner(k)
  c = Core::Buffer.i64(3, 1)
  c[0] + k
end

def outer(out)
  a = Core::Buffer.i64(4, 0)
  b = Core::Buffer.i64(2, 7)
  out[0] = inner(a.size) + b[1]
  0
end
