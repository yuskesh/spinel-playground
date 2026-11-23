def break_while(buf, n_buf, i)
  k = 0
  while k < 10
    break if k == i
    k = k + 1
  end
  k
end
