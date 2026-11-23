# frozen_string_literal: true
#
# tests/doom-core/rebirth-guard.rb — Full refuses a pending rebirth before the step.
#
#   ruby tests/doom-core/rebirth-guard.rb
#
# Doom::Core::Session#before_step! reads game_pl_playerstate from the session's
# core_state and raises RebirthRefused when it is PST_REBORN. Checked on a small
# session laid out like the real one (core_state i64, a slot table): it passes
# at every other state, refuses at PST_REBORN whether the store is prepared
# bytes or a filled array, reads the cell its slot names and no other, reads
# the caller's live cell instead of the store when handed a reader (Full's
# route, examples/doom/core/full/route.rb), and refuses to guess when the
# session has no such slot or is closed.
require "tmpdir"
ROOT = File.expand_path("../..", __dir__)
require File.join(ROOT, "examples/doom/core/full/session")
S = Doom::Core::Session
fails = []
check = ->(label, ok) { puts "  #{ok ? 'pass' : 'FAIL'} #{label}"; fails << label unless ok }
refused = lambda do |s|
  s.before_step!
  false
rescue Doom::Core::RebirthRefused
  true
end
Dir.mktmpdir("rebirth-guard") do |d|
  write = lambda do |name, rows, slot_field|
    File.write(File.join(d, "#{name}-buffers.tsv"),
               "#name\trole\telement\tcount\tinitial\ncore_state\tpersistent\ti64\t3\tprepared:core_state\n")
    File.write(File.join(d, "#{name}-slots.tsv"),
               "#field\tindex\tinitial\torigin\n" + rows.each_with_index.map { |f, i| "#{f}\t#{i}\t0\tGame@@x#{i}\n" }.join)
    [File.join(d, "#{name}-buffers.tsv"), File.join(d, "#{name}-slots.tsv")]
  end
  fields = %w[game_gametic game_pl_playerstate game_pl_health]
  b, sl = write.("real", fields, "game_pl_playerstate")
  open_with = ->(cells, bpath = b, spath = sl) { S.open(buffers: bpath, slots: spath, prepared: { "core_state" => cells.pack("q<*") }) }
  [0, 1].each { |st| check.("state #{st} is not refused", !refused.(open_with.([7, st, 100]))) }
  check.("PST_REBORN is refused", refused.(open_with.([7, 2, 100])))
  check.("a PST_REBORN in another cell is not read as the player's state", !refused.(open_with.([2, 0, 2])))
  s = open_with.([7, 2, 100])
  s.buffers["core_state"].store = [7, 2, 100]
  check.("a filled-array store is read the same way", refused.(s))
  b2, sl2 = write.("moved", %w[game_gametic game_pl_health game_pl_playerstate], nil)
  check.("the slot table decides the cell", refused.(open_with.([7, 0, 2], b2, sl2)) && !refused.(open_with.([7, 2, 0], b2, sl2)))
  b3, sl3 = write.("none", %w[game_gametic game_pl_health game_other], nil)
  begin
    open_with.([0, 0, 2], b3, sl3).before_step!
    check.("a session with no playerstate slot is refused, not guessed", false)
  rescue Doom::Core::RebirthRefused
    check.("a session with no playerstate slot is refused, not guessed", false)
  rescue Doom::Core::SessionError => e
    check.("a session with no playerstate slot is refused, not guessed", e.message.include?("no slot for game_pl_playerstate"))
  end
  # A READER, as Full's route passes one: the live cell decides, not the store.
  asked = []
  live = ->(v) { ->(f) { asked << f; v } }
  s = open_with.([7, 0, 100])
  check.("a reader's PST_REBORN is refused while the store holds 0", begin
    s.before_step!(read: live.(2))
    false
  rescue Doom::Core::RebirthRefused
    true
  end)
  check.("and it is asked for the player's state by name", asked == ["game_pl_playerstate"])
  s = open_with.([7, 2, 100])
  check.("a reader's 0 is not refused while the store holds PST_REBORN", begin
    s.before_step!(read: live.(0))
    true
  rescue Doom::Core::RebirthRefused
    false
  end)
  c = open_with.([7, 0, 100])
  c.close
  begin
    c.before_step!
    check.("a closed session is refused", false)
  rescue Doom::Core::SessionError => e
    check.("a closed session is refused", e.message.include?("closed") && !e.is_a?(Doom::Core::RebirthRefused))
  end
end
puts "rebirth-guard: #{fails.empty? ? 'all pass' : "#{fails.length} fail"}"
exit(fails.empty? ? 0 : 1)
