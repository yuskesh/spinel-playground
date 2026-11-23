# frozen_string_literal: true
#
# tests/doom-core/statusbar-branches.rb — the status bar's rare branches, forced.
#
#   ruby tests/doom-core/statusbar-branches.rb IWAD [SOURCE]
#
# NO RECORDED DEMO REACHES THEM. Over the whole of DEMO1, DEMO2 and DEMO3 the
# original's status bar never shows "n/a" for the ready weapon's ammo and never
# erases a key box to draw a different key -- source-port.rb counts both, as
# `furniture branches`, and all three demos print 0 for each. So the recorded
# oracle says nothing about the port's copies of those two branches, and they
# were "migrated" on the strength of code that never ran.
#
# THIS DRIVES BOTH, on synthetic frames, through the ORIGINAL Doom::StatusBar#draw
# and the port's dc_draw_statusbar (examples/doom/core/src/statusbar.rb, or SOURCE
# when given) side by side, and compares the whole screen and the backing store
# after every frame. The frames: the pistol with its ammo, then the blue skull
# key, then the blue CARD in its place (an erase), then the fist, whose ammo kind
# is none (an "n/a").
#
# THE ERASE RUNS SKULL TO CARD, WHICH THE GAME DOES NOT DO, AND THAT IS THE
# POINT. A key box erases only when the key it shows changes. In play that is a
# card replaced by its skull -- and a skull patch is 7 rows over the card's 5,
# covering every pixel the erase would restore, so there a port that skipped the
# erase draws the same screen. Measured over all 30 ordered pairs of the six key
# patches: the erase is visible exactly when a skull (3, 4, 5) gives way to a
# card (0, 1, 2). So the check uses one of those, the only transitions where a
# wrong erase can show.
#
# THE CHECK FAILS WHEN THE PORT'S BRANCH IS WRONG, and screens.sh shows it: it
# runs this once over the port as written and once over each of two copies with
# one branch broken.
#
# IT RUNS THE RUBY DEFINITIONS, NOT THE COMPILED ENTRY. The compiled sbdraw is
# built from the same source and compared on every recorded frame, but those
# frames never take these two branches, so the compiled copies of them are not
# executed by anything yet.
#
# Prints one line per frame and then
#   `statusbar-branches: F frames, na N, key-erase K, disagree D`
# and exits 1 when a frame disagrees or a branch was not taken.
iwad, source = ARGV
iwad or abort("usage: statusbar-branches.rb IWAD [SOURCE]")
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
$VERBOSE = nil
%w[bytes wad info statusbar].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }
def core_fail(category) = raise("core_fail #{category}")
load(source || File.join(ROOT, "examples/doom/core/src/statusbar.rb"))

wad = Doom::Wad.new(iwad)
sb = Doom::StatusBar.new(wad)
weaponowned = [1, 1, 0, 0, 0, 0, 0, 0, 0]
sb.start(weaponowned)
iv = ->(n) { sb.instance_variable_get(n) }
flag = ->(v) { v == true ? 1 : (v == false ? 0 : v) }

# The port's storage, laid out as source-port.rb lays it out off the route.
I_FIRSTTIME, I_OLD_ARMSBG, I_OLD_FACE, I_FACEINDEX, I_NOTDEATHMATCH = 0, 1, 2, 3, 4
state = [flag.(iv.(:@firsttime)), flag.(iv.(:@old_armsbg)), iv.(:@old_face), 0, 0]
old_arms = iv.(:@old_arms).dup
old_keybox = iv.(:@old_keybox).dup
keyboxes = [0, 0, 0]
wad_bytes = wad.data.bytes
lump_pos = Array.new(wad.count) { |i| wad.lump(i).pos }
tables = %i[@tallnum @shortnum @armsgray @faces @keys].map { |n| iv.(n).dup }
ones = %i[@tallw @shortw @sbar @tallpercent @armsbg].map { |n| [iv.(n)] }
port_screen = Array.new(320 * 200, 0)
port_backing = Array.new(320 * 32, 0)
orig_screen = ("\0" * (320 * 200)).b

ammo = [50, 0, 0, 0]
maxammo = [200, 50, 300, 50]
# [what, keyboxes, ready weapon, ammo kind]
FRAMES = [
  ["pistol", [-1, -1, -1], 1, 0],
  ["blue skull", [3, -1, -1], 1, 0],
  ["blue card in its place", [0, -1, -1], 1, 0],
  ["fist", [0, -1, -1], 0, -1]
].freeze

counts = Hash.new(0)
disagree = 0
FRAMES.each_with_index do |(what, kb, ready, ammokind), f|
  sb.instance_variable_set(:@keyboxes, kb.dup)
  sb.instance_variable_set(:@notdeathmatch, true)
  # The branch counts, taken from the original's own state as source-port.rb takes them.
  counts["na"] += 1 if ammokind < 0 || ammokind >= 4
  kb.each_with_index do |v, i|
    o = iv.(:@old_keybox)[i]
    counts["key-erase"] += 1 if v != -1 && o != -1 && (o != v || iv.(:@firsttime))
  end
  # The boundary copy: the game's state into the port's.
  keyboxes.replace(kb)
  state[I_FACEINDEX] = iv.(:@faceindex)
  state[I_NOTDEATHMATCH] = 1

  sb.draw(orig_screen, 100, 0, ammo, maxammo, weaponowned, ready, ammokind)
  st = dc_draw_statusbar(port_screen, port_backing, wad_bytes, lump_pos, state,
                         old_arms, old_keybox, keyboxes, *tables, *ones,
                         ammo, maxammo, weaponowned,
                         I_FIRSTTIME, I_OLD_ARMSBG, I_OLD_FACE, I_FACEINDEX, I_NOTDEATHMATCH,
                         100, 0, ammokind)
  got = port_screen.pack("C*")
  at = (0...got.bytesize).find { |o| got.getbyte(o) != orig_screen.getbyte(o) }
  bat = (0...port_backing.length).find { |o| port_backing[o] != iv.(:@backing).getbyte(o) }
  ok = st.zero? && at.nil? && bat.nil?
  disagree += 1 unless ok
  puts "frame #{f} #{what}: status #{st} " +
       (ok ? "agrees" : "screen #{at ? "differs at #{at} (x #{at % 320} y #{at / 320})" : 'agrees'}, " \
                        "backing #{bat ? "differs at #{bat}" : 'agrees'}")
end
puts "statusbar-branches: #{FRAMES.length} frames, na #{counts['na']}, key-erase #{counts['key-erase']}, disagree #{disagree}"
exit(disagree.zero? && counts["na"].positive? && counts["key-erase"].positive? ? 0 : 1)
