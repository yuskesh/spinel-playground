def probe(a, b, buf, n_buf)
  s = 0
  a.upto(b, 2) { |i| s += i }
  s
end
