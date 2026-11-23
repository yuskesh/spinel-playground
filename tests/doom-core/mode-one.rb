# frozen_string_literal: true
#
# tests/doom-core/mode-one.rb — the source conversion in job mode 1, and where it stops.
#
#   ruby tests/doom-core/mode-one.rb WAD
#
# Full's conversion (Doom::Core::Resources::SourceSelect) and the reference's
# (Doom::Core::Reference.field_value) turn the renderer's source references
# into a selector and a base. In job mode 1 each accepts only a renderer that
# has set no source yet -- session open -- and says so otherwise; job modes
# other than 0 and 1 are refused outright. After a frame, the reference reads
# job mode 1's own @dc_srcbase. Checked on E1M1 before and after one frame,
# each refusal by its message.
#
# "Before the first frame" is decided by the direct path's references being
# empty (@dc_srcbuf, @ds_source), not by a frame count: the renderer keeps
# none.
ROOT = File.expand_path("../..", __dir__)
%w[wad level texnames texture sprites info random game render jobs executor].each do |f|
  require File.join(ROOT, "examples/doom/lib/doom", f)
end
require File.join(ROOT, "examples/doom/core/full/resources")
require File.join(ROOT, "examples/doom/core/full/reference")
fails = []
check = ->(label, ok) { puts "  #{ok ? 'pass' : 'FAIL'} #{label}"; fails << label unless ok }
said = lambda do |&blk|
  blk.call
rescue Doom::Core::Resources::PreparationError, Doom::Core::Reference::ReferenceError => e
  e.message
end
wad = Doom::Wad.new(ARGV[0] || abort("usage: mode-one.rb WAD"))
lv = Doom::Level.new(wad, "E1M1", 1)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, 2, rnd, tx)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, Doom::Sprites.new(wad, Doom::Info.sprnames),
                       g, 10, false, 1)
r.job_mode = 1
ss = ->(which, part) { Doom::Core::Resources::SourceSelect.new(r, which, part).value }
ref = ->(ivar) { Doom::Core::Reference.field_value({ "Renderer" => r }, "Renderer@@#{ivar}") }

check.("at session open, Full converts job mode 1: no column and no span source",
       [ss.("dc", "res"), ss.("dc", "base"), ss.("ds", "res"), ss.("ds", "base")] == [-1, 0, -1, 0])
check.("and so does the reference",
       [ref.("dc_srcres"), ref.("dc_srcbase"), ref.("ds_source"), ref.("ds_source.base")] == [[:ok, -1], [:ok, 0], [:ok, -1], [:ok, 0]])
r.clear_screen
r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
check.("after one frame, Full refuses",
       said.() { ss.("dc", "res") } ==
         "source-select converts job mode 1 only before the first frame, and this renderer has set a source")
check.("and the reference refuses the three it compares at session open only",
       %w[dc_srcres ds_source ds_source.base].map { |iv| said.() { ref.(iv) } } ==
         %w[dc_srcres ds_source ds_source.base].map { |iv| "Renderer@@#{iv}: job mode 1 is converted before the first frame only" })
check.("while it reads job mode 1's own column base",
       ref.("dc_srcbase") == [:ok, r.instance_variable_get(:@dc_srcbase)])
r.job_mode = 2
check.("job mode 2 is refused by Full", said.() { ss.("dc", "res") } == "source-select converts job modes 0 and 1; job mode is 2")
check.("and by the reference", said.() { ref.("dc_srcres") } == "Renderer@@dc_srcres: the conversion is for job modes 0 and 1")
puts(fails.empty? ? "mode-one: all pass" : "mode-one: #{fails.length} fail")
exit(fails.empty? ? 0 : 1)
