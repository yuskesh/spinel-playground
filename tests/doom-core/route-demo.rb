# frozen_string_literal: true
#
# tests/doom-core/route-demo.rb — a demo played through Full's job-mode-1 route.
#
#   ruby tests/doom-core/route-demo.rb WAD DEMO NTICS LIB HEADERS WORKDIR [--mode N]
#
# LIB links the three generated adapters and the kernel objects
# (tests/doom-core/harness/artifacts.sh: dc_core_entries, dc_adapter_generate
# and dc_adapter_link); HEADERS is the adapter generator's directory. WORKDIR
# receives the catalog the demo's map measures and the layout generated from
# it.
#
# FULL PREPARES, THEN ONLY THE ENTRIES RUN THE GAME. The objects below are
# constructed from the IWAD and the configuration, as
# tests/doom-core/build-prepared.rb constructs them, and read once by
# Doom::Core::Resources.prepared; no tick and no frame of the original runs.
# Every tic after that is Doom::Core::Route#tic.
#
# It prints one line per tic, `gametic viewhash fullhash`, in the recordings'
# format (tests/doom-core/fixtures/screens), after a `#gametic` header.
#
# --mode N prepares the renderer in job mode N, which the route must refuse
# unless N is 1: the control for the mode assertion. --plant FIELD=VALUE@TIC
# writes VALUE into the field's live cell before tic TIC: the controls for the
# checks the route makes between calls. --snapshot T,T... --snapdir DIR writes
# the state before each tic T, read back from the registry, as DIR/route-T.bin
# over DIR/layout-T.tsv (tests/doom-core/route-lane.rb); a plant for tic T is
# made before that tic's snapshot.
ROOT = File.expand_path("../..", __dir__)
%w[wad texnames texture level random info sprites game render statusbar hud jobs executor input record
   demo bytes].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }
require File.join(ROOT, "examples/doom/core/full/resources")
require File.join(ROOT, "examples/doom/core/full/route")
require File.join(ROOT, "examples/doom/core/full/reference")
require "tmpdir"
require_relative "route-lane"
require_relative "route-prep"

usage = "usage: route-demo.rb WAD DEMO NTICS LIB HEADERS WORKDIR [--mode N] [--plant FIELD=VALUE@TIC] [--snapshot T,... --snapdir DIR]"
ARGV.length >= 6 or abort(usage)
wad_path, demo_name, ntics, lib, headers, work = ARGV
ntics = Integer(ntics, 10)
mode = (i = ARGV.index("--mode")) ? Integer(ARGV[i + 1], 10) : 1
plant = (i = ARGV.index("--plant")) && ARGV[i + 1].match(/\A(\w+)=(-?\d+)@(\d+)\z/) ||
        (ARGV.include?("--plant") && abort(usage))
snaps = (i = ARGV.index("--snapshot")) ? RouteLane.checkpoints(ARGV[i + 1]) : []
snapdir = (i = ARGV.index("--snapdir")) && ARGV[i + 1]
snaps.empty? || snapdir or abort(usage)
Dir.mkdir(work) unless Dir.exist?(work)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# --- the configuration, measured ------------------------------------------------
wad = Doom::Wad.new(wad_path)
demo = Doom::Demo.new(wad, demo_name, "")
script = File.join(work, "script.txt")
File.write(script, "0 10 forward\n")
# --- the objects Full constructs before any tic ----------------------------------
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
tx.precache_all
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
rnd = Doom::Random.new
rnd.clear
game = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sprites = Doom::Sprites.new(wad, Doom::Info.sprnames)
colormap = wad.bytes_by_name("COLORMAP")
renderer = Doom::Renderer.new(lv, wad, colormap, tx, sprites, game, 10, false, 1)
renderer.job_mode = mode
statusbar = Doom::StatusBar.new(wad)
statusbar.start(game.pl_weaponowned)
objects = {
  "Doom::Wad" => wad, "Doom::Textures" => tx, "Doom::Level" => lv, "Doom::Random" => rnd,
  "Doom::Game" => game, "Doom::Sprites" => sprites, "Doom::Renderer" => renderer,
  "Doom::StatusBar" => statusbar,
  "Doom::Hud" => Doom::Hud.new(wad, renderer.screenwidth, renderer.screenheight, 1),
  "Doom::KeyScript" => Doom::KeyScript.new(script), "Doom::KeyState" => Doom::KeyState.new,
  "Doom::TiccmdBuilder" => Doom::TiccmdBuilder.new, "Doom::DemoWriter" => Doom::DemoWriter.new(2, 1, 1, 40_000),
  # the renderer's own, which job mode 1 runs: not objects of this file's making
  "Doom::Jobs" => renderer.instance_variable_get(:@jobs),
  "Doom::JobExecutor" => renderer.instance_variable_get(:@exec)
}
Doom::Core::Reference.check_graph(objects)
# THE LAYOUT FOR THIS MAP, and the session over it (tests/doom-core/route-prep.rb):
# prepared.tsv's lengths are E1M1's; for another map each prepared row's length
# is what Full produced for it, and state-schema.rb then checks every one
# against the count the measured catalog gives the field.
session = RoutePrep.session(root: ROOT, work: work, wad: wad, map: demo.mapname, script: script,
                            objects: objects, label: "route-demo")
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# --- the route ------------------------------------------------------------------
route = nil
t2 = nil
n = [ntics, demo.numtics].min
puts "#gametic\tviewhash\tfullhash"
sw = renderer.screenwidth
vh = renderer.viewheight
sh = renderer.screenheight
take_snapshot = lambda do |t|
  next unless snaps.include?(t)
  rows = RouteLane.rows(File.join(work, "gen", "snapshot.tsv"), t)
  RouteLane.write_layout(rows, File.join(snapdir, "layout-#{t}.tsv"))
  s0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  File.binwrite(File.join(snapdir, "route-#{t}.bin"), route.snapshot(rows))
  RouteLane.write_open_only(SESSION_OPEN_ONLY.keys.to_h { |f| [f, route.read(f)] },
                            File.join(snapdir, "route-#{t}.open-only.tsv"))
  warn format("route-demo: snapshot before tic %d: %d field(s), %.1f s", t, rows.length,
              Process.clock_gettime(Process::CLOCK_MONOTONIC) - s0)
end
begin
# Inside the rescue: a route refused at session open is reported like any other.
route = Doom::Core::Route.open(lib: lib, headers: headers, session: session)
t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times do |t|
  if plant && Integer(plant[3], 10) == t
    route.write(plant[1], Integer(plant[2], 10))
    warn "route-demo: planted #{plant[1]} = #{plant[2]} before tic #{t}"
  end
  take_snapshot.(t)
  gametic, frame = route.tic(t, [demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t]],
                             t == 2 ? 320 : 0)
  gametic == t + 1 && frame == t + 1 or
    abort("route-demo: tic #{t}: the step answered gametic #{gametic} and the render frame #{frame}")
  scr = route.screen
  puts "#{t}\t#{Doom::Bytes.fnv1a64_hex_range(scr, 0, sw * vh)}\t#{Doom::Bytes.fnv1a64_hex_range(scr, 0, sw * sh)}"
end
# the state after the last tic
take_snapshot.(n)
rescue Doom::Core::SessionError => e
  # A refusal ends the run. What was called before it is said, so a control can
  # tell a refusal before a call from one after it.
  warn "route-demo: refused (#{e.class.name.split('::').last}): #{e.message}"
  calls = route ? route.calls : Hash.new(0)
  warn "route-demo: calls: step #{calls['doom_core_step']}, render #{calls['doom_core_render']}"
  exit 1
end
t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
refused = route.close
session.close
warn format("route-demo: %s %d tic(s); prepare %.1f s, bind %.1f s, tics %.1f s; %d release(s) refused",
            demo_name, n, t1 - t0, t2 - t1, t3 - t2, refused)
exit(refused.zero? ? 0 : 1)
