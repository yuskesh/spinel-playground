# spinel-tier: arena
# The form exactly as in the original case (ObjectSpace.define_finalizer). Checks that arenacheck
# fails it with the tier's vocabulary before the vendor's whole-AOT refusal.
obj = "x"
ObjectSpace.define_finalizer(obj) { }
puts "unreachable"
