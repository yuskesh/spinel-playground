# s6 r4: empty-menu platform -- edge/kv on native.  native is "a platform
# whose menu is still empty" (R016 T-3): the refusal cites the menu, and the
# menu -- not this program, not any code -- is what a future implementation
# would widen.  Checked standalone through spinel-capcheck (--platform native):
# the native lane has no driver hook in Phase 1 (see E090 Honest boundary).
require "edge/kv"
puts Edge::KV.probe
