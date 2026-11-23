def break_value(buf, n_buf, i)
  k = 0
  while k < 4
    k = k + 1
    break 7 if k == i
  end
  k
end
