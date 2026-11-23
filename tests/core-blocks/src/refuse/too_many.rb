def probe(a, b, buf, n_buf)
  s = 0
  a.times { |i, j| s += i }
  s
end
