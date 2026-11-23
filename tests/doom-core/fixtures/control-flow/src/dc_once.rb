# The index is an expression with a side effect: `dc_tick` writes a counter and
# answers 0. If `buf[dc_tick(...)] += 1` evaluated its index twice the counter
# would read 2, so the counter IS the measurement.
def dc_tick(counter, n_counter)
  counter[0] += 1
  0
end

def dc_once(buf, n_buf, counter, n_counter, i)
  buf[dc_tick(counter, n_counter)] += 10
  buf[0]
end
