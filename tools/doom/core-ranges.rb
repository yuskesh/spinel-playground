# frozen_string_literal: true
#
# tools/doom/core-ranges.rb — decision 0018's observed evidence: the range of
# every entry buffer over one demo, through the compiled entries.
#
#   ruby tools/doom/core-ranges.rb WAD DEMO LIB HEADERS WORKDIR OUTPUT
#
# LIB and HEADERS are what tests/doom-core/route-demo.rb takes: the shared
# object linking the three generated adapters and the kernel objects, and the
# adapter generator's directory (tests/doom-core/harness/artifacts.sh's
# dc_route_adapter and dc_adapter_link). WORKDIR receives the catalog the demo's
# map measures and the layout generated from it.
#
# THE ROUTE IS route-demo.rb's. Full prepares the session from the original
# objects (tests/doom-core/route-prep.rb), and from then on every tic is the
# input, step and render entries through Doom::Core::Route; nothing of the
# original runs after preparation and nothing is compared with anything.
#
# WHAT IT READS. After every tic, every buffer the route holds is read straight
# from the adapter registry -- spinel_adapter_registry_find answers the entry
# (element at 0, count at 8, data at 16) and its data is unpacked at its
# element -- and the buffer's minimum and maximum over all its elements are
# kept. A `resource` buffer, which CORE only reads, is read at session open and
# after the last tic. The read is checked against the route's own
# (Route#cells) on five buffers at session open, and a value planted after the
# last tic must be seen by it: a reader that saw nothing would otherwise
# report narrow ranges. Full's own writes between the calls (Route#put after the
# session opens) are noted as well. What this cannot see is a value an entry
# stores and overwrites within one call: tools/doom/core-store-ranges.rb
# records those, and decision 0018's evidence is the union of the two.
#
# OUTPUT: field, role, element, count, min, max, min_tic, max_tic. Tic -1 is
# the state at session open, before the first tic. core_state's slots are not
# rows: decision 0018 keeps them i64.

ROOT = File.expand_path("../..", __dir__)
%w[wad texnames texture level random info sprites game render statusbar hud jobs executor input record
   demo bytes].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }
require File.join(ROOT, "examples/doom/core/full/resources")
require File.join(ROOT, "examples/doom/core/full/route")
require File.join(ROOT, "examples/doom/core/full/reference")
require "fiddle"
require File.join(ROOT, "tests/doom-core/route-lane")
require File.join(ROOT, "tests/doom-core/route-prep")

ARGV.length == 6 or abort("usage: core-ranges.rb WAD DEMO LIB HEADERS WORKDIR OUTPUT")
wad_path, demo_name, lib, headers, work, out = ARGV
Dir.mkdir(work) unless Dir.exist?(work)
wad = Doom::Wad.new(wad_path)
demo = Doom::Demo.new(wad, demo_name, "")
script = File.join(work, "script.txt")
File.write(script, "0 10 forward\n")
# The preparation, as route-demo.rb makes it.
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
tx.precache_all
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
rnd = Doom::Random.new
rnd.clear
game = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sprites = Doom::Sprites.new(wad, Doom::Info.sprnames)
renderer = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sprites, game, 10, false, 1)
renderer.job_mode = 1
statusbar = Doom::StatusBar.new(wad)
statusbar.start(game.pl_weaponowned)
objects = {
  "Doom::Wad" => wad, "Doom::Textures" => tx, "Doom::Level" => lv, "Doom::Random" => rnd,
  "Doom::Game" => game, "Doom::Sprites" => sprites, "Doom::Renderer" => renderer,
  "Doom::StatusBar" => statusbar,
  "Doom::Hud" => Doom::Hud.new(wad, renderer.screenwidth, renderer.screenheight, 1),
  "Doom::KeyScript" => Doom::KeyScript.new(script), "Doom::KeyState" => Doom::KeyState.new,
  "Doom::TiccmdBuilder" => Doom::TiccmdBuilder.new, "Doom::DemoWriter" => Doom::DemoWriter.new(2, 1, 1, 40_000),
  "Doom::Jobs" => renderer.instance_variable_get(:@jobs),
  "Doom::JobExecutor" => renderer.instance_variable_get(:@exec)
}
Doom::Core::Reference.check_graph(objects)
session = RoutePrep.session(root: ROOT, work: work, wad: wad, map: demo.mapname, script: script,
                            objects: objects, label: "core-ranges")
route = Doom::Core::Route.open(lib: lib, headers: headers, session: session)

# The registry's element codes (Doom::Core::Route::ELEM) and how each unpacks.
UNPACK = { 1 => ["u8", "C"], 2 => ["i32", "l<"], 3 => ["u32", "L<"], 4 => ["i64", "q<"], 5 => ["i8", "c"], 6 => ["u16", "S<"], 7 => ["i16", "s<"] }.freeze
WIDTH = { 1 => 1, 2 => 4, 3 => 4, 4 => 8, 5 => 1, 6 => 2, 7 => 2 }.freeze
find = Fiddle::Function.new(Fiddle.dlopen(lib)["spinel_adapter_registry_find"], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
ids = route.instance_variable_get(:@ids)
cells = lambda do |id|
  e = Fiddle::Pointer.new(find.call(id).to_i)
  e.null? and abort("core-ranges: registry_find(#{id}) answered no entry")
  el, = e[0, 4].unpack("l<")
  count, data = e[8, 16].unpack("q<Q<")
  UNPACK.key?(el) or abort("core-ranges: id #{id} holds element code #{el}, which this reader does not unpack")
  next [] if count.zero?
  Fiddle::Pointer.new(data)[0, count * WIDTH[el]].unpack("#{UNPACK[el][1]}*")
end

roles = {}
File.foreach(File.join(ROOT, "examples/doom/core/state.tsv")) do |l|
  next if l.start_with?("#") || l.strip.empty?
  f = l.split("\t")
  roles[f[0]] = f[1]
end
buffers = ids.keys.reject { |f| f == "core_state" || f.start_with?("derived:") }.sort
live = buffers.reject { |f| roles[f] == "resource" }
res = buffers - live

rng = {}
note = lambda do |f, vals, t|
  next if vals.empty?
  mn, mx = vals.minmax
  r = (rng[f] ||= [mn, mx, t, t])
  if mn < r[0] then r[0] = mn; r[2] = t end
  if mx > r[1] then r[1] = mx; r[3] = t end
end
scan = ->(t, which) { which.each { |f| note.(f, cells.(ids[f]), t) } }

# FULL'S OWN WRITES between the calls -- the tic's command, the render entry's
# scalars, the weapon sprites -- are stores too, made through Route#put after
# the session is open. Each is noted at the tic it is made in.
field_of_id = ids.invert
tic_now = [-1]
recording = [true]
route.singleton_class.prepend(Module.new do
  define_method(:put) do |id, element, i, v|
    f = field_of_id[id]
    note.(f, [v], tic_now[0]) if recording[0] && f && f != "core_state" && !f.start_with?("derived:")
    super(id, element, i, v)
  end
end)

ctl = live.sort_by { |f| [session.id(f).count, f] }.first(4) + res.sort_by { |f| [session.id(f).count, f] }.first(1)
ctl.each do |f|
  cells.(ids[f]) == route.cells(f) or abort("core-ranges: control: the direct read of #{f} is not Route#cells")
end
warn "core-ranges: control: the direct read equals Route#cells for #{ctl.join(', ')}"

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
scan.(-1, buffers)
n = demo.numtics
n.times do |t|
  tic_now[0] = t
  gametic, frame = route.tic(t, [demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t]],
                             t == 2 ? 320 : 0)
  gametic == t + 1 && frame == t + 1 or
    abort("core-ranges: tic #{t}: the step answered gametic #{gametic} and the render frame #{frame}")
  scan.(t, live)
end
scan.(n, res)
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

# The planted control, after the ranges are taken: a value no buffer holds.
recording[0] = false
pf = live.find { |f| session.id(f).element == "i64" } or abort("core-ranges: no i64 buffer to plant")
route.write(pf, 1 << 40, 0)
cells.(ids[pf])[0] == (1 << 40) or abort("core-ranges: control: a planted #{pf}[0] = 2**40 is not seen")
warn "core-ranges: control: #{pf}[0] = 2**40 planted after the last tic is seen by the direct read"

File.open(out, "w") do |io|
  io.puts "# Generated by tools/doom/core-ranges.rb: #{demo_name}, map #{demo.mapname}, #{n} tic(s); tic -1 is session open"
  io.puts "#field\trole\telement\tcount\tmin\tmax\tmin_tic\tmax_tic"
  buffers.each do |f|
    b = session.id(f)
    mn, mx, a, z = rng[f] || ["-", "-", "-", "-"]
    io.puts [f, roles[f], b.element, b.count, mn, mx, a, z].join("\t")
  end
end
refused = route.close
session.close
warn format("core-ranges: %s %s %d tic(s), %d buffer(s) (%d resource), %.1f s; %d release(s) refused",
            demo_name, demo.mapname, n, buffers.size, res.size, wall, refused)
exit(refused.zero? ? 0 : 1)
