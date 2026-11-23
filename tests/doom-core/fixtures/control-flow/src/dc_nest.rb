# `break` and `next` target the NEAREST loop. The inner loop's break must leave
# the inner loop only, so the outer one still runs its remaining iterations.
def dc_nest(buf, n_buf, i)
  o = 0
  total = 0
  while o < 3
    k = 0
    while k < 3
      k = k + 1
      break if k == i
      total = total + 1
    end
    o = o + 1
  end
  total
end
