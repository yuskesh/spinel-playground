# spinel-tier: arena
# The second form of escape: each assignment looks unboxed, but whole-program
# type inference widens the result to poly. Invisible to a per-write check,
# it shows only in one line of Compiler.gvars (spinel-typedump globals; a known trap).
$slot = 0
$slot = "now a string"
puts $slot.to_s
