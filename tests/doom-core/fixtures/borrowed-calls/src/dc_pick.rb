# Decision 0008 task 3's positive fixture, written BEFORE the implementation
# and refused by the pin as it stands. What it asks for is a call that carries
# a borrowed buffer:
#
#   * `dc_pick` receives `data` with a declared count `n_data` and passes the
#     buffer -- not a copy and not a length -- to `dc_at`;
#   * `dc_at` is not an entry and has no contract of its own, so its bound has
#     to come from the caller's descriptor rather than from a declaration;
#   * `n_data = n_data + 100` reassigns the SCALAR the count was read from.
#     That must not enlarge the helper's bound: the bound belongs to the
#     descriptor, and the scalar is an ordinary argument that happens to have
#     been declared as the count.
#
# With descriptor count 1 over storage [11, 99]: index 0 returns OK and 11;
# index 1 returns BOUNDS, leaves the result at whatever the caller had (123),
# and must not touch the guard element 99.

def dc_at(data, i)
  data[i]
end

def dc_pick(data, n_data, i)
  n_data = n_data + 100
  dc_at(data, i)
end
