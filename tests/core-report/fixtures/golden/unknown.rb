# A golden fixture: loops the rules cannot bound, each for a different reason,
# and a bounded loop whose occurrence is unknown because its enclosing loop is.

def gd_unknown(cnt, n_cnt, buf, n_buf, n)
  i = 0
  while i < buf[0]
    cnt[0] += 1
    j = 0
    while j < n
      cnt[1] += 1
      j += 1
    end
    i += 1
  end
  a = 0
  while a < n
    cnt[2] += 1
    b = a + 1
    while b < n
      cnt[3] += 1
      b += 1
    end
    a += 1
  end
  t = 0
  s = 0
  while t < n
    cnt[0] += 1
    s += 1
    next if s == 3
    t += 1
  end
  0
end
