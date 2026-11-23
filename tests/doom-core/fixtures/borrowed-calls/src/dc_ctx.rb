# The entry's buffer context: dc_ctx_sum is handed the entry's `a` on every
# call, so it reads `a`'s pointer and bound from the context; dc_ctx_pick is
# handed `a` on one call and `b` on another, so it keeps its pointer and
# bound arguments.
def dc_ctx_sum(x, n)
  s = 0
  i = 0
  while i < n
    s = s + x[i]
    i += 1
  end
  s
end

def dc_ctx_pick(y, i)
  y[i]
end

def dc_ctx(a, n_a, b, n_b)
  dc_ctx_sum(a, 3) + dc_ctx_pick(a, 0) + dc_ctx_pick(b, 1) * 100
end
