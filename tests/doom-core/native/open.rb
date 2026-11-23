# tests/doom-core/native/open.rb — the playable program's session, opened and written out.
#
#   (compiled by the pinned Spinel, see tests/doom-core/native.sh)
#   open WAD DEMO SCRIPT OUTDIR
#
# Builds the objects bin/doom.rb builds for DEMO's map, measures the catalog
# (full/native_catalog.rb), opens the session (full/native_session.rb), runs
# the generated preparation (full/nativeprep.rb) and writes the session's
# canonical snapshot as OUTDIR/native-0.bin and the catalog as
# OUTDIR/native-catalog.tsv, for tests/doom-core/native.sh to compare with
# CRuby's preparation of the same configuration.
require_relative "../../../examples/doom/lib/doom/wad"
require_relative "../../../examples/doom/lib/doom/level"
require_relative "../../../examples/doom/lib/doom/texnames"
require_relative "../../../examples/doom/lib/doom/texture"
require_relative "../../../examples/doom/lib/doom/sprites"
require_relative "../../../examples/doom/lib/doom/statusbar"
require_relative "../../../examples/doom/lib/doom/hud"
require_relative "../../../examples/doom/lib/doom/render"
require_relative "../../../examples/doom/lib/doom/info"
require_relative "../../../examples/doom/lib/doom/random"
require_relative "../../../examples/doom/lib/doom/demo"
require_relative "../../../examples/doom/lib/doom/game"
require_relative "../../../examples/doom/lib/doom/bytes"
require_relative "../../../examples/doom/lib/doom/input"
require_relative "../../../examples/doom/lib/doom/record"
require_relative "../../../examples/doom/lib/doom/specials"
require_relative "../../../examples/doom/lib/doom/tables"
require_relative "../../../examples/doom/core/full/nativeprep"
require_relative "../../../examples/doom/core/full/native_session"
require_relative "../../../examples/doom/core/full/native_catalog"

wad = Doom::Wad.new(ARGV[0])
demo = Doom::Demo.new(wad, ARGV[1], "")
out = ARGV[3]
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
sb = Doom::StatusBar.new(wad)
sb.start(g.pl_weaponowned)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
hud = Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1)
r.job_mode = 1
ks = Doom::KeyScript.new(ARGV[2])
kst = Doom::KeyState.new
tc = Doom::TiccmdBuilder.new
dw = Doom::DemoWriter.new(2, 1, 1, 40000)
jobs = r.instance_variable_get(:@jobs)
ex = r.instance_variable_get(:@exec)

cat = Doom::Core::NativeCatalog.measure(wad, lv, tx, sp, r.screenwidth, r.screenheight,
                                        ks.instance_variable_get(:@from).length)
File.open(out + "/native-catalog.tsv", "w") do |f|
  cat.each { |k, v| f.puts("count\t" + k + "\t" + v.to_s) }
end
s = Doom::Core::NativeSession.new(cat)
Doom::Core::NativePrep.prepare(s, wad, tx, lv, rnd, g, sp, r, sb, hud, ks.instance_variable_get(:@code),
                               ks.instance_variable_get(:@from), ks.instance_variable_get(:@to), kst, tc, dw, jobs, ex)
n = s.write_snapshot(out + "/native-0.bin")
puts "native-open: snapshot " + n.to_s + " byte(s)"
