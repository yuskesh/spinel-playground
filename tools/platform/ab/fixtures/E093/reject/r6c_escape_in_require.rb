# spinel-tier: arena
# The form where the escape happens **inside a resolved require**, not in the entry.
# arenacheck's input is the entry + the whole resolved require graph (the same reach as the platform check).
require "e093/store"

e093_remember("k", "v")
puts "unreachable"
