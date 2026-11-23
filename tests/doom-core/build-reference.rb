# frozen_string_literal: true
#
# tests/doom-core/build-reference.rb — decision 0008 task 5's reference route.
#
#   ruby tests/doom-core/build-reference.rb WAD LAYOUT SCHEMA [OUT]
#
# Builds the game the way `bin/doom.rb` builds it, reads every field the
# schema names out of those objects, and writes the canonical snapshot. What
# it cannot read it REPORTS rather than skips: a field nobody can read from
# the reference is a field this comparison says nothing about, and saying
# nothing is not the same as agreeing.
#
# The IWAD is the caller's and is not in this repository.

ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/core/full/reference")
%w[wad level texnames texture sprites statusbar hud render info random game
   input record jobs executor].each do |f|
  require_relative File.join(ROOT, "examples/doom/lib/doom", f)
end
R = Doom::Core::Reference
wad = Doom::Wad.new(ARGV[0])
lv = Doom::Level.new(wad, "E1M1", 1)
tn = Doom::TextureNames.new(wad)
tx = Doom::Textures.new(wad, tn)
rnd = Doom::Random.new; rnd.clear
g = Doom::Game.new(wad, lv, 2, rnd, tx)
cm = wad.bytes_by_name("COLORMAP")
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
sb = Doom::StatusBar.new(wad); sb.start(g.pl_weaponowned)
r = Doom::Renderer.new(lv, wad, cm, tx, sp, g, 10, false, 1)
hud = Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1)
require "tmpdir"
SCRIPT = File.join(Dir.mktmpdir("ref-script"), "s.txt")
# `<from> <to> <key>[,<key>...]`, the format tests/doom/fixtures/scripts uses.
File.write(SCRIPT, "0 10 forward\n")
script = Doom::KeyScript.new(SCRIPT)
ks = Doom::KeyState.new
tc = Doom::TiccmdBuilder.new
rec = Doom::DemoWriter.new(2, 1, 1, 40_000)
# The renderer's own Jobs and JobExecutor (render.rb:465-466): a reference
# observes the program's objects and builds none of its own (check_graph below).
jobs = r.instance_variable_get(:@jobs)
exec = r.instance_variable_get(:@exec)
objects = { "Game" => g, "Level" => lv, "Random" => rnd, "Renderer" => r,
            "StatusBar" => sb, "Hud" => hud, "Textures" => tx, "Sprites" => sp,
            "Wad" => wad, "KeyState" => ks, "TiccmdBuilder" => tc,
            "DemoWriter" => rec, "Jobs" => jobs, "JobExecutor" => exec,
            "KeyScript" => script }
R.check_graph(objects)
layout = R.read_layout(ARGV[1])
origins = R.read_origins(ARGV[2])
res = R.snapshot(layout: layout, origins: origins, objects: objects)
# The ivars the schema says are one of its fields, checked to be the same object.
begin
  puts "aliases #{R.check_aliases(R.read_aliases(ARGV[2]), objects)} identical"
rescue R::ReferenceError => e
  puts "aliases refused #{e.message}"
end
puts "fields #{layout.length}"
puts "bytes #{res.bytes.bytesize}"
puts "unreachable #{res.unreachable.length}"
puts "added #{res.added.length} #{res.added.join(',')}"
puts "errors #{res.errors.length}"
res.errors.first(6).each { |e| puts "E #{e}" }
# EVERY FIELD THE ENCODER REFUSED, whatever it refused it for, one per line.
#
# Naming only the SHAPE refusals let every other kind through. Mac review
# declared `StatusBar@oldhealth`, which holds -1, as a one-element `u8`:
# `encode` reported it and `errors` counted it, but the field was not named
# here, so nothing excluded it -- the reference side got the schema's INITIAL
# bytes, the session was built from that same initial, and the comparator
# counted it as agreeing. A placeholder on both sides is not agreement.
#
# A refusal is a refusal whatever its reason: nil, type, range, shape. The
# grouped shape report below is a SUBSET of this, kept because one wrong count
# expression makes many wrong fields and that is the work list.
res.errors.each do |e|
  n = e[/\A(\w+):/, 1]
  puts "NOENCODE #{n}" if n
end
puts "noencode #{res.errors.count { |e| e[/\A(\w+):/, 1] }}"
# SHAPE ERRORS, GROUPED BY THE COUNT EXPRESSION THAT PRODUCED THEM.
#
# The encoder used to truncate an original longer than the schema's count and
# zero-pad a shorter one -- changing the original before comparing against it.
# It refuses now, so each such field lands here. A flat list of 182 names is
# not a work list; the COUNT EXPRESSION is, because one wrong expression makes
# many wrong fields. Printed every run so what remains is visible without
# anyone re-deriving it.
shape = res.errors.filter_map do |e|
  m = /\A(\w+): shape: the original holds (\d+) element\(s\) and the schema declares (\d+)/.match(e)
  m && [m[1], m[2].to_i, m[3].to_i]
end
# Built OUTSIDE the branch on purpose: a run with no shape errors at all is the
# goal state, and `by` must be an empty table there rather than nil.
by = Hash.new { |h, k| h[k] = [] }
# And the count is printed there too -- "0 across 0" -- rather than nothing,
# so the goal state is a stated measurement and not an absent line.
puts "shape-errors 0 across 0 count expression(s)" if shape.empty?
unless shape.empty?
  decl = {}
  File.foreach(ARGV[2]) do |ln|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    decl[f[0]] = f[3]
  end
  shape.each { |n, have, want| by[decl[n] || "?"] << [n, have, want] }
  puts "shape-errors #{shape.length} across #{by.size} count expression(s)"
  # NAMED, one per line, so a comparator can EXCLUDE them. A field the encoder
  # refused gets the schema's initial bytes here, and the session is built from
  # the same initial -- so it would compare EQUAL and be counted as agreement.
  # That is how refusing to reshape could otherwise turn 88 differing fields
  # into 86: two of them stopped being encoded and started "agreeing".
  shape.each { |n, _, _| puts "SHAPEFIELD #{n}" }
  # And the GROUPS, largest first, so a run says what the remaining work is by
  # count expression rather than by 177 field names.
  #
  # This loop used to sit inside the `unreachable` loop below, where it printed
  # the whole group table once per unreachable field -- three times, which is
  # what every run showed. Worse, it was reached ONLY when something was
  # unreachable, and `by` was nil when there were no shape errors at all: a run
  # with the counts right and any unreachable field would have died on
  # `nil.sort_by` instead of going green. It prints here now, once, and `by` is
  # an empty table rather than nil on the path that has no shape errors.
  by.sort_by { |_, v| -v.length }.each do |expr, v|
    n, have, want = v.first
    puts format("S %-22s %4d field(s)  e.g. %s holds %d, declared %d",
                expr, v.length, n, have, want)
  end
end
# The same for what could not be reached at all: its bytes here are the
# schema's initial, so comparing it against the schema compares the schema
# with itself. Named so a comparator can leave it out rather than count it.
res.unreachable.each do |u|
  n = u[/\A(\w+)/, 1]
  puts "UNREACHFIELD #{n}" if n
end
# Which classes the unreachable ones belong to, so the report is a fact about
# the harness rather than a list.
by = Hash.new(0)
res.unreachable.each { |u| by[u[/\((?:no reference object for )?([A-Za-z]+)/, 1] || "?"] += 1 }
puts "byclass " + by.sort.map { |k, v| "#{k}=#{v}" }.join(" ")
File.binwrite(ARGV[3], res.bytes) if ARGV[3]
