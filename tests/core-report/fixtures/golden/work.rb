# A golden fixture: every loop has a static_proof bound, and the work bound
# composes a nest, a callee reached from inside it and a conjunct.

def gd_fill(cnt, width)
  x = 0
  while x < width
    cnt[2] += 1
    x += 1
  end
  0
end

def gd_work(cnt, n_cnt, w, h, lo, hi)
  y = 0
  while y < h
    cnt[0] += 1
    gd_fill(cnt, w)
    y += 1
  end
  k = hi
  while lo < k && k > 0
    cnt[1] += 1
    k -= 2
  end
  0
end
