# tests/doom-core/native/bound.rb — the playable program's tic, over resources it did not allocate.
#
#   (compiled by the pinned Spinel with bound_map.o, see tests/doom-core/bound-resources.sh)
#   bound WAD DEMO TICS OUTDIR alloc
#   bound WAD DEMO TICS OUTDIR bound IMAGEDIR
#   bound WAD DEMO TICS OUTDIR refuse IMAGEDIR
#
# Builds the objects bin/doom.rb builds for `-playdemo DEMO -core`, opens the
# session and runs the generated preparation, as bin/doom.rb's core_play does.
# Then, by mode:
#
#   alloc   writes the session at open (OUTDIR/native-0.bin, with the catalog
#           as OUTDIR/native-catalog.tsv, for tools/doom/session-image.rb) and
#           plays TICS tics through the entries over the storage the session
#           allocated, writing each frame's hashes to OUTDIR/alloc.frames
#           and its derived index tables to OUTDIR/derived.tsv;
#   bound   maps IMAGEDIR/resources.bin read-only (bound_map.c), binds every
#           resource field to its offset there (NativeSession#bind_resource,
#           decision 0021), plays the same tics to OUTDIR/bound.frames, and
#           then tries one write to a bound resource, which must be refused;
#   refuse  maps the image and asks for four binds that must each be refused
#           by its own message: a field that is not a resource, an address
#           not aligned for the element, an address whose end overflows, and
#           a count other than the schema's.
#
# The frames are bin/doom.rb's -frames lines, so they compare directly with
# tests/doom-core/fixtures/screens.
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
require_relative "../../../examples/doom/core/full/native_loop"

module BoundMap
  ffi_func :doom_bound_map, [:str], :int64
end

# image.tsv's rows: name role element count part offset bytes
def image_rows(dir)
  rows = []
  File.read(dir + "/image.tsv").split("\n").each do |ln|
    next if ln.start_with?("#")
    rows << ln.split("\t")
  end
  rows
end

def map_image(dir)
  base = BoundMap.doom_bound_map(dir + "/resources.bin")
  if base <= 0
    $stderr.puts "bound: could not map " + dir + "/resources.bin (" + base.to_s + ")"
    exit 2
  end
  base
end

def play(s, demo, tics, path)
  ff = File.open(path, "w")
  ff.puts("#gametic\tviewhash\tfullhash")
  sw = 320
  sh = 200
  vh = 168
  screen = Doom::Bytes.buffer(sw * sh, 0)
  t = 0
  while t < tics
    Doom::Core::NativeLoop.demo_command(s, demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t],
                                        demo.buttons[t])
    Doom::Core::NativeLoop.step(s, t)
    Doom::Core::NativeLoop.render(s, t, t + 1)
    Doom::Core::NativeLoop.screen(s, screen, sw * sh)
    ff.puts("#{t}\t#{Doom::Bytes.fnv1a64_hex_range(screen, 0, sw * vh)}\t" \
            "#{Doom::Bytes.fnv1a64_hex_range(screen, 0, sw * sh)}")
    t += 1
  end
  ff.close
  t
end

# The session's own derived index tables, as `table position value`, for the
# lane to compare with the image's.
def dump_table(f, s, name, id, n)
  k = 0
  while k < n
    f.puts(name + "\t" + k.to_s + "\t" + s.get_i64(id, k).to_s)
    k += 1
  end
end

def write_derived(s, path)
  f = File.open(path, "w")
  dump_table(f, s, "derived:input-slots.tsv", s.input_slots, Doom::Core::NativePrep::INPUT_SLOTS.length)
  dump_table(f, s, "derived:step-slots.tsv", s.step_slots, Doom::Core::NativePrep::STEP_SLOTS.length)
  dump_table(f, s, "derived:render-slots.tsv", s.render_slots, Doom::Core::NativePrep::RENDER_SLOTS.length)
  dump_table(f, s, "derived:render-zero.tsv", s.render_zero, Doom::Core::NativePrep::RENDER_ZERO.length)
  f.close
end

def refused(s, label, name, address, count)
  begin
    s.bind_resource(name, address, count)
    puts "bound: " + label + ": bound, not refused"
  rescue Doom::Core::NativeSessionError => e
    puts "bound: " + label + ": " + e.message
  end
end

wad = Doom::Wad.new(ARGV[0])
demo = Doom::Demo.new(wad, ARGV[1], "")
tics = ARGV[2].to_i
out = ARGV[3]
mode = ARGV[4]
mapname = "E#{demo.episode}M#{demo.map}"
lv = Doom::Level.new(wad, mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
sb = Doom::StatusBar.new(wad)
sb.start(g.pl_weaponowned)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
hud = Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1)
r.job_mode = Doom::Core::NativeLoop::JOB_MODE
dw = Doom::DemoWriter.new(demo.skill, demo.episode, demo.map, 40000)
none = Array.new(0, 0)
cat = Doom::Core::NativeCatalog.measure(wad, lv, tx, sp, r.screenwidth, r.screenheight, 0)
s = Doom::Core::NativeSession.new(cat)
Doom::Core::NativePrep.prepare(s, wad, tx, lv, rnd, g, sp, r, sb, hud, none, none, none,
                               Doom::KeyState.new, Doom::TiccmdBuilder.new, dw,
                               r.instance_variable_get(:@jobs), r.instance_variable_get(:@exec))

if mode == "alloc"
  File.open(out + "/native-catalog.tsv", "w") do |f|
    cat.each { |k, v| f.puts("count\t" + k + "\t" + v.to_s) }
  end
  n = s.write_snapshot(out + "/native-0.bin")
  write_derived(s, out + "/derived.tsv")
  puts "bound: alloc: snapshot " + n.to_s + " byte(s)"
  puts "bound: alloc: " + play(s, demo, tics, out + "/alloc.frames").to_s + " tic(s)"
elsif mode == "bound"
  base = map_image(ARGV[5])
  nb = 0
  first_u8 = ""
  image_rows(ARGV[5]).each do |row|
    next unless row[4] == "resource"
    s.bind_resource(row[0], base + row[5].to_i, row[3].to_i)
    first_u8 = row[0] if first_u8 == "" && row[2] == "u8" && row[3].to_i > 0
    nb += 1
  end
  puts "bound: bound " + nb.to_s + " resource buffer(s) into the read-only image"
  puts "bound: bound: " + play(s, demo, tics, out + "/bound.frames").to_s + " tic(s)"
  begin
    s.put(first_u8, 0, 0)
    puts "bound: write to " + first_u8 + ": written, not refused"
  rescue Doom::Core::NativeSessionError => e
    puts "bound: write to " + first_u8 + ": " + e.message
  end
elsif mode == "refuse"
  base = map_image(ARGV[5])
  rows = image_rows(ARGV[5])
  owned = ""
  wide = ""
  wide_at = 0
  wide_n = 0
  u8 = ""
  u8_n = 0
  rows.each do |row|
    owned = row[0] if owned == "" && row[1] == "persistent"
    if wide == "" && row[4] == "resource" && row[2] != "u8" && row[2] != "i8" && row[3].to_i > 0
      wide = row[0]
      wide_at = row[5].to_i
      wide_n = row[3].to_i
    end
    if u8 == "" && row[4] == "resource" && row[2] == "u8" && row[3].to_i >= 3
      u8 = row[0]
      u8_n = row[3].to_i
    end
  end
  # Each violates one rule: the count is the schema's and the address the
  # image's unless the case is about that.
  refused(s, "role", owned, base, s.count(owned))
  refused(s, "alignment", wide, base + wide_at + 1, wide_n)
  refused(s, "overflow", u8, -2, u8_n)
  refused(s, "count", wide, base + wide_at, wide_n + 1)
else
  $stderr.puts "bound: mode is alloc, bound or refuse"
  exit 2
end
