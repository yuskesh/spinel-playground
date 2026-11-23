# E091 reject subject e1: an edge/* require without --host-api.  The driver must
# say which flag is missing (and name the unresolved feature) instead of letting
# the build fail deep inside the generated C.
require "edge/kv"

puts Edge::KV.get("MY_KV", "k").to_s
