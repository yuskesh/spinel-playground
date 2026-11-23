# frozen_string_literal: true
#
# tests/doom-core/graph-guard.rb — a reference reads the program's objects and builds none.
#
#   ruby tests/doom-core/graph-guard.rb WAD
#
# Doom::Core::Reference.check_graph: the classes examples/doom/bin/doom.rb
# constructs in main are the roots, and every other object a reference is
# handed must be one a root holds. Checked on E1M1's objects, built as
# bin/doom.rb builds them:
#   * the renderer's own Jobs and JobExecutor pass;
#   * a Jobs and a JobExecutor constructed the way build-prepared.rb and
#     build-reference.rb constructed them before 2026-09-17 are refused, each
#     by name;
#   * the renderer's own Jobs is refused when no root holding it is handed over;
#   * an object under a key that is not its class's name is refused, so a
#     second Renderer cannot be handed over to vouch for what it holds;
#   * a program whose main does not construct the Renderer makes the Renderer
#     itself a non-root, refused -- the roots are read from the program, not
#     listed here.
ROOT = File.expand_path("../..", __dir__)
require File.join(ROOT, "examples/doom/core/full/reference")
%w[wad level texnames texture sprites info random game render jobs executor].each do |f|
  require File.join(ROOT, "examples/doom/lib/doom", f)
end
require "tmpdir"
R = Doom::Core::Reference
fails = []
check = ->(label, ok) { puts "  #{ok ? 'pass' : 'FAIL'} #{label}"; fails << label unless ok }
refusal = lambda do |objects, roots = R.program_roots|
  R.check_graph(objects, roots: roots)
  nil
rescue R::ReferenceError => e
  e.message
end

roots = R.program_roots
check.("bin/doom.rb's main constructs the renderer and the game, and no Jobs",
       roots.include?("Renderer") && roots.include?("Game") && !roots.include?("Jobs"))
wad = Doom::Wad.new(ARGV[0] || abort("usage: graph-guard.rb WAD"))
lv = Doom::Level.new(wad, "E1M1", 1)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, 2, rnd, tx)
cm = wad.bytes_by_name("COLORMAP")
r = Doom::Renderer.new(lv, wad, cm, tx, Doom::Sprites.new(wad, Doom::Info.sprnames), g, 10, false, 1)
own = { "Wad" => wad, "Level" => lv, "Textures" => tx, "Random" => rnd, "Game" => g, "Renderer" => r,
        "Jobs" => r.instance_variable_get(:@jobs), "JobExecutor" => r.instance_variable_get(:@exec) }
check.("the renderer's own Jobs and JobExecutor pass", refusal.(own).nil?)

# THE CONSTRUCTION THE BUILDERS MADE, as they wrote it.
jobs = Doom::Jobs.new(r.screenwidth, r.screenheight)
exec = Doom::JobExecutor.new(jobs, cm, tx.tex_atlas, tx.flat_atlas, wad.data, r.fuzzoffset, r.screenwidth,
                             r.viewwindowx, r.viewwindowy, r.viewheight)
msg = refusal.(own.merge("Jobs" => jobs))
check.("a constructed Jobs is refused by name",
       msg == "Jobs is not the program's: bin/doom.rb does not construct one and no object it constructs holds this one")
msg = refusal.(own.merge("JobExecutor" => exec))
check.("a constructed JobExecutor is refused by name", msg.to_s.start_with?("JobExecutor is not the program's"))
msg = refusal.(own.reject { |k, _| k == "Renderer" })
check.("the renderer's Jobs is refused when its holder is not handed over", msg.to_s.start_with?("Jobs is not the program's"))

# ONE OBJECT PER CLASS, UNDER ITS NAME: a second Renderer, built at setblocks
# 11 so that its Jobs is sized by the screen, handed over under a key nothing
# reads, would otherwise let its Jobs pass as the program's.
r2 = Doom::Renderer.new(lv, wad, cm, tx, Doom::Sprites.new(wad, Doom::Info.sprnames), g, 11, false, 1)
msg = refusal.(own.merge("Jobs" => r2.instance_variable_get(:@jobs), "Extra" => r2))
check.("a second Renderer under another key is refused by its key",
       msg == "Extra holds a Renderer; each object is handed over under its own class's name")
msg = refusal.(own.merge("Jobs" => r.instance_variable_get(:@exec)))
check.("an object under another class's key is refused", msg == "Jobs holds a JobExecutor; each object is handed over under its own class's name")
check.("the prepared side's Doom:: keys are the same names", refusal.(own.transform_keys { |k| "Doom::#{k}" }).nil?)

Dir.mktmpdir("graph-guard") do |d|
  src = File.read(R::PROGRAM)
  planted = src.sub("r = Doom::Renderer.new(", "r = make_renderer(")
  planted != src or abort("graph-guard: the program no longer constructs its renderer as this control expects")
  path = File.join(d, "doom.rb")
  File.write(path, planted)
  msg = refusal.(own, R.program_roots(path))
  check.("a program that does not construct the Renderer makes it a non-root, refused",
         msg.to_s.start_with?("Renderer is not the program's"))
end
puts(fails.empty? ? "graph-guard: all pass" : "graph-guard: #{fails.length} fail")
exit(fails.empty? ? 0 : 1)
