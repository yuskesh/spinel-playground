# The local holds an INTEGER; the right-hand side is still boolean, so the
# short-circuit is in the subset. On the skipped path Ruby reads nil from `t`.
def scint(buf, n_buf, flag)
  (flag != 0) && (t = buf[0]) > 0
  t
end
