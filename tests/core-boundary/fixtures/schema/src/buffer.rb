def accumulate(dst, n_dst, src, n_src)
  i = 0
  total = 0
  while i < n_dst
    total = total + dst[i]
    i = i + 1
  end
  total
end
