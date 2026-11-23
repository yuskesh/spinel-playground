# spinel-tier: core
# s6 r1: tier violation -- core declares itself, then requires an arena+
# capability.  Expected: REJECT tier-violation naming edge/kv, arena+, core.
require "edge/kv"
puts Edge::KV.probe
