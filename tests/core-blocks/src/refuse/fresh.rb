def probe(a, b, buf, n_buf)
  s = 0
  a.times do |i|
    t = 5 if i == 0
    s += t
  end
  s
end
