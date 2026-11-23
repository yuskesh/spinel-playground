def probe(a, b, buf, n_buf)
  s = 0
  i = 1
  a.times { |i| s += i }
  s + i
end
