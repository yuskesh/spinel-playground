def dc_bump(count, n_count)
  count[0] += 1
  true
end

def dc_short(count, n_count, flag)
  if (flag != 0) && dc_bump(count, n_count)
    return 1
  end
  0
end
