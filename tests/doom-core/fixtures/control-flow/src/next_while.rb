def next_while(buf, n_buf, i)
  k = 0
  s = 0
  while k < 4
    k = k + 1
    next if k == i
    s = s + k
  end
  s
end
