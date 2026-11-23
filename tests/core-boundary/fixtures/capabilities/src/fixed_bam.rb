# Extracted for decision 0007 task 5 from the Full helper.
#
#   original: examples/doom/lib/doom/fixed.rb (module Doom::Fixed)
#   upstream: DG/tables.h, the binary angle measure, via R007 section 4.7
#
# `Doom::Fixed.bam` -- ANGLE NORMALIZATION, which decision 0007's stage-1 exit
# names beside the fixed-point arithmetic and which the first four extractions
# left out. It was found by reading the exit criteria against what had been
# built, not by a lane failing, and that is worth recording: the four helpers
# and their thirty cases were accepted without it.
#
# A DOOM angle is a full turn in 32 unsigned bits, so normalising one is the
# mask and nothing else -- `ANG90` is 0x40000000 and four of them are 0x1_0000_0000,
# which is zero again. Every angle the game computes goes through here:
# `@mobj_angle[actor] = bam(@mobj_angle[actor] - ANG90 / 2)` and its like.
#
# Adaptations: none. One masking operation, and the subset takes it.
#
# The DECLARATION is where the care is. The result is 0 to 4294967295, which is
# not an i32, so this entry answers `i64` where the other four answer `i32`.
# Declaring it `i32` would refuse every angle at or above ANG180 -- measured,
# and the case table carries those values on both sides of that edge.

def fixed_bam(v)
  v & 0xffffffff
end
