# tests/doom/cases-aux/ticcmd_combination.rb — the keydown table to ticcmd, for
# the up+left question.
#
# The second layer of three.  The SDL shim's event handling is probed by
# tests/doom/native/key-combination-probe.c; this is what the game makes of the
# table that probe fills, and it is compiled by the pinned Spinel so it is the
# same code path bin/doom.rb runs rather than a CRuby-only reading.
#
# The third layer -- a real key press producing an SDL event -- is not here and
# cannot be: the OS, the window server and SDL's input backend sit in it.
#
# Each case is built for eight tics and reported at two points, because
# `turnheld` carries across tics: while it is below SLOWTURNTICS (6) the builder
# uses ANGLETURN[2] = 320, and after that ANGLETURN[speed] = 640.  A single
# sample would report one of those as "the" value, and which one depends on how
# many tics happened to be built -- which is not a property of the input.
#
# The settled value here, 640, is what a demo records as 768: G_WriteDemoTiccmd
# stores angleturn as ((v + 128) >> 8) and reads it back << 8, so 640 becomes
# byte 3 and restores to 768.  quantize_angle! does that deliberately, so a
# .lmp is exactly what the running game did.  A reading of 768 from a recorded
# demo and 640 from an in-memory ticcmd are the same measurement on either side
# of that quantisation, not a disagreement.
require_relative "../../../examples/doom/lib/doom/input"

UP = 0xad
LEFT = 0xac

def row(name, keys)
  ks = Doom::KeyState.new
  keys.each { |k| ks.press(k) }
  b = Doom::TiccmdBuilder.new
  early = 0
  8.times do |t|
    b.build(ks.down)
    early = b.angleturn if t == 1
  end
  puts "#{name}\tforward=#{b.forwardmove}\tside=#{b.sidemove}\tturn=#{b.angleturn}\tturn_early=#{early}"
end

row("nothing", [])
row("up alone", [UP])
row("left alone", [LEFT])
row("up+left", [UP, LEFT])
row("up, left released", [UP])
row("left, up released", [LEFT])
