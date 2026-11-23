# frozen_string_literal: true
#
# tests/doom-core/render-diff.rb — the render entry against the original, one frame at a time.
#
#   ruby tests/doom-core/render-diff.rb WAD DEMO TICS [--stop-after N] [--src DIR] [--coverage FILE]
#                                       [--exclude-only FIELD,...]
#
# step-diff.rb's twin for render, in JOB MODE 1 -- the mode the native program
# renders in (the owner's option (A)). The original game runs every tic; before
# each frame the renderer's, the status bar's and the HUD's state is copied into
# doom_core_render's layout -- every buffer it takes, resolved through
# examples/doom/core/entries/fields.tsv, and every slot of render-slots.tsv --
# the entry renders the copy and the original loop's frame (clear_screen at tic
# 0, render_player_view, the status bar's draw, the HUD's draw) renders itself,
# and every field is compared after: the screen, the job banks, the clip and
# plane tables, the drawsegs, the vissprites, the counters, the status bar's
# cells; and the frame number the entry answers. Every other field the harness
# holds must be unchanged by the original's frame. not-taken.tsv's same: pairs
# are checked on the original before the first frame.
#
# EXCLUDED, BY NAME, and printed: the three cells tests/doom-core/route-lane.rb
# compares at session open only -- renderer_dc_srcres, renderer_ds_srcres and
# renderer_ds_srcbase, each with its reason there -- and core_frame, which no
# original object holds and is checked against this run's frame count. What a
# selector selects is compared where it lands: in the job banks and on the
# screen. renderer_dc_srcofs was excluded too until `--exclude-only core_frame`
# showed it never differs; it is compared on every frame.
#
# RESOURCES ARE COPIED ONCE. A field whose schema role is `resource` does not
# change in a frame, so its copy is made at the start and handed over every
# frame; the port's copy and the original are compared at the end of the run,
# so a port that wrote into one is caught, though not at the frame it did.
#
# It runs the port in CRuby. --src loads the port from another directory (a
# planted defect -- which must change a VALUE, not only the text (see
# source-port.rb's poison rule)); --coverage FILE writes the port's line coverage.
ROOT = File.expand_path("../..", __dir__)
%w[wad level texnames texture sprites statusbar hud render info random demo game bytes hires].each do |f|
  require File.join(ROOT, "examples/doom/lib/doom", f)
end

wad_path, demo_name, ntics = ARGV[0], ARGV[1], ARGV[2].to_i
stop_after = (i = ARGV.index("--stop-after")) ? ARGV[i + 1].to_i : 20
# --scale S renders at 320S x 200S, as bin/doom.rb does with a larger window: the
# status bar is drawn onto a 320x200 shadow and copied up, which is the render
# entry's other status-bar path.
SCALE = (i = ARGV.index("--scale")) ? ARGV[i + 1].to_i : 1
(1..8).cover?(SCALE) or abort("render-diff: --scale is 1..8")
wad_path && demo_name && ntics.positive? or abort("usage: render-diff.rb WAD DEMO TICS [...]")
cov_path = (i = ARGV.index("--coverage")) ? ARGV[i + 1] : nil
if cov_path
  require "coverage"
  require "json"
  Coverage.start(lines: true)
end

class CoreFail < StandardError; end
def core_fail(what) = raise(CoreFail, "core_fail(#{what.inspect})")
src = (i = ARGV.index("--src")) ? ARGV[i + 1] : File.join(ROOT, "examples/doom/core/src")
# THE PORT HOLDS ANGLES AS SIGNED PATTERNS (decision 0022 section 2.4): the
# angle buffers and slots examples/doom/core/full/reference.rb names are
# handed in, and compared, as the original's words converted the same way.
# --raw-repr hands them in unconverted, the planted control that shows the
# conversion is needed.
require File.join(ROOT, "examples/doom/core/full/reference")
RAW_REPR = ARGV.delete("--raw-repr")
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
File.readlines(File.join(ROOT, "examples/doom/core/sources.tsv"))
    .reject { |l| l.start_with?("#") || l.strip.empty? }
    .each { |l| load File.join(src, l.split("\t").first) }

# --- the original, as bin/doom.rb builds it, in job mode 1 ----------------------
wad = Doom::Wad.new(wad_path)
demo = Doom::Demo.new(wad, demo_name, "")
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
sb = Doom::StatusBar.new(wad)
sb.start(g.pl_weaponowned)
hud = Doom::Hud.new(wad, 320 * SCALE, 200 * SCALE, SCALE)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, SCALE)
# bin/doom.rb's sbshadow: one byte unscaled, the 320x200 surface when scaled
SHADOW = Doom::Bytes.buffer(SCALE == 1 ? 1 : 320 * 200, 0)
r.job_mode = 1
jobs = r.instance_variable_get(:@jobs)
exec = r.instance_variable_get(:@exec)
OWNERS = { "Game" => g, "Level" => lv, "Textures" => tx, "Sprites" => sp, "Renderer" => r,
           "Jobs" => jobs, "JobExecutor" => exec, "Wad" => wad, "StatusBar" => sb, "Hud" => hud }.freeze

FIELDS = {}
ROLE = {}
File.foreach(File.join(ROOT, "examples/doom/core/state.tsv")) do |l|
  next if l.start_with?("#")
  f = l.chomp.split("\t")
  FIELDS[f[0]] = f[5]
  ROLE[f[0]] = f[1]
end
LUMPS = (0...wad.count).map { |k| wad.lump(k) }
def value_of(field)
  o = FIELDS.fetch(field) { abort("render-diff: no field #{field}") }
  return LUMPS.map(&:pos) if o == "Lump@@pos"
  return LUMPS.map(&:size) if o == "Lump@@size"
  return OWNERS["Hud"].instance_variable_get(:@texts).inject([0]) { |a, x| a << a.last + x.bytesize } if o == "Hud@@texts.ofs"
  cls, ivar = o.split("@@", 2)
  owner = OWNERS.fetch(cls) { abort("render-diff: #{field} belongs to #{cls}, which this harness does not hold") }
  owner.instance_variable_get("@#{ivar}")
end
def cell(v) = v == true ? 1 : (v == false ? 0 : v)
def copy_in(v)
  case v
  when Array then v.first.is_a?(String) ? v.join.bytes : v.map { |x| cell(x) }
  when String then v.bytes
  when Integer, true, false then [cell(v)]
  else abort("render-diff: a field holds #{v.class}")
  end
end
# a field's cells as the port holds them
def port_cells(v, field)
  c = copy_in(v)
  return c if RAW_REPR || !Doom::Core::Reference.i32_bits?(field)

  c.map { |x| Doom::Core::Reference.pattern(x) }
rescue Doom::Core::Reference::ReferenceError => e
  abort("render-diff: #{field}: #{e.message}")
end
# a slot cell as the port holds it
def port_cell(v, field)
  c = cell(v)
  return c if RAW_REPR || !Doom::Core::Reference.i32_bits?(field)

  Doom::Core::Reference.pattern(c)
rescue Doom::Core::Reference::ReferenceError => e
  abort("render-diff: #{field}: #{e.message}")
end

# --- the layout -----------------------------------------------------------------
# THE ENTRY'S OWN SIGNATURE AND FIELD MAP (examples/doom/core/entries/fields.tsv).
# The added fields -- the capacity cells, the BSP stack, the status bar's
# shadow -- and the zero table are the harness's to fill; the frame counter
# has no original and is checked against the frames this run made.
sig = File.read(File.join(src, "doomentry.rb"))[/^def doom_core_render\(([^)]*)\)/m, 1].split(",").map(&:strip)
ENTRY_FIELD = File.readlines(File.join(ROOT, "examples/doom/core/entries/fields.tsv"))
                  .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }
                  .select { |f| f[0] == "doom_core_render" }.to_h { |f| [f[1], f[2]] }
ADDED = %w[core_state core_render_caps core_bsp_stack core_sb_shadow].freeze
buffer_field = ENTRY_FIELD.reject { |_, f| ADDED.include?(f) || f.start_with?("derived:") }
table = ->(name) { File.readlines(File.join(ROOT, "examples/doom/core/entries", name)).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t")[-1] } }
slot_fields = table.("render-slots.tsv")
# Jobs#reset zeroes more counters than the spine names: in this harness's
# core_state they get slots of their own after the table's.
RESET_ZERO = table.("render-zero.tsv").freeze
extra = RESET_ZERO - slot_fields
all_slots = slot_fields + extra
ZERO_SLOTS = RESET_ZERO.map { |f| all_slots.index(f) }.freeze
FRAME_SLOT = all_slots.index("core_frame")
# THE SAME TABLE UNDER TWO NAMES (not-taken.tsv's same: rows) is a claim about
# the original, checked here before the first frame: one object, or equal bytes.
File.foreach(File.join(ROOT, "examples/doom/core/entries/not-taken.tsv")) do |l|
  e, f, kind, = l.chomp.split("\t")
  next unless e == "doom_core_render" && kind.to_s.start_with?("same:")
  a, b = value_of(f), value_of(kind.delete_prefix("same:"))
  a.equal?(b) || copy_in(a) == copy_in(b) or abort("render-diff: #{f} is not the same as #{kind.delete_prefix('same:')}")
end
# --exclude-only LIST replaces the list: `--exclude-only core_frame` is the
# measurement tests/doom-core/route-lane.rb names its session-open-only cells
# from (every other field compared, the frame counter checked apart).
EXCLUDED = ((i = ARGV.index("--exclude-only")) ? ARGV[i + 1].split(",")
            : %w[renderer_dc_srcres renderer_ds_srcres renderer_ds_srcbase core_frame]).freeze
EXCLUDED.include?("core_frame") or abort("render-diff: core_frame has no original and is always checked apart; exclude it")
covered = buffer_field.values | all_slots
plain = ->(f) { FIELDS.fetch(f).match?(/\A(Game|Level|Textures|Sprites|Renderer|Jobs|JobExecutor|Wad|StatusBar|Hud)@@[a-z_][a-z0-9_]*\z/) }
uncovered = FIELDS.keys.select { |f| plain.(f) && !covered.include?(f) && !EXCLUDED.include?(f) && ROLE[f] != "resource" }
                  .select { |f| v = value_of(f); v.is_a?(Array) || v.is_a?(String) || v.is_a?(Integer) || v == true || v == false }
BSP_CELLS = 3 * (lv.instance_variable_get(:@num_nodes) + 2)
puts "render-diff: #{buffer_field.size} buffer(s) and #{all_slots.size} slot(s) compared " \
     "(#{EXCLUDED.join(', ')} excluded by design); #{uncovered.size} other held field(s) required unchanged"

# A held field's value as it stands, for "unchanged": a copy, not a conversion.
def snap(v) = v.is_a?(Array) ? v.map { |x| x.is_a?(String) ? x.dup : x } : (v.is_a?(String) ? v.dup : v)

def diff(port, v, field)
  orig = port_cells(v, field)
  return nil if port == orig
  n = [port.length, orig.length].max
  k = (0...n).find { |x| port[x] != orig[x] }
  "cell #{k}: port #{port[k].inspect} original #{orig[k].inspect} " \
    "(#{(0...n).count { |x| port[x] != orig[x] }} cell(s), lengths #{port.length}/#{orig.length})"
end

disagreed = Hash.new(0)
errors = Hash.new(0)
bad = 0
n = [ntics, demo.numtics].min
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
port_seconds = 0.0
frames = 0
resource_copy = nil
n.times do |t|
  rnd.tic = t
  320.times { rnd.m_random } if t == 2
  g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
  st_randomnumber = rnd.m_random
  m = g.player_mo
  atk = g.pl_attacker
  kind = atk < 0 ? 0 : (atk == m ? 1 : 2)
  bga = atk >= 0 ? g.point_to_angle2(g.mobj_x[m], g.mobj_y[m], g.mobj_x[atk], g.mobj_y[atk]) : 0
  sb.ticker(st_randomnumber, g.pl_health, g.pl_weaponowned, g.pl_cards, g.pl_damagecount,
            g.pl_bonuscount, g.pl_attackdown, g.pl_powers[0], kind, bga, g.mobj_angle[m])
  hud.ticker(g.take_message)
  # the boundary setters: Full writes these fields, and the copy below carries them
  r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
  r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
  r.extralight = g.extralight

  resource_copy ||= buffer_field.select { |_, f| ROLE[f] == "resource" }.to_h { |nm, f| [nm, port_cells(value_of(f), f)] }
  bufs = buffer_field.to_h { |name, field| [name, resource_copy[name] || port_cells(value_of(field), field)] }
  state = all_slots.map { |f| f == "core_frame" ? frames : port_cell(value_of(f), f) }
  rx = (0...slot_fields.length).to_a
  bufs["rx"] = rx
  bufs["state"] = state
  bufs["zero_slots"] = ZERO_SLOTS.dup
  bufs["rv_caps"] = [0, 0, 0, 0]
  bufs["bsp_stack"] = Array.new(BSP_CELLS, 0)
  bufs["sb_shadow"] = SHADOW.bytes
  before = uncovered.to_h { |f| [f, snap(value_of(f))] }
  ak = Doom::Info.weapon_ammo[g.pl_readyweapon]
  scal = { "first" => t.zero? ? 1 : 0, "health" => g.pl_health, "armorpoints" => g.pl_armorpoints, "ammokind" => ak,
           "viewx" => g.viewx, "viewy" => g.viewy, "viewz" => g.viewz,
           "viewangle" => RAW_REPR ? g.viewangle : Doom::Core::Reference.pattern(g.viewangle) }
  args = sig.map do |nm|
    next scal[nm] if scal.key?(nm)
    next bufs.fetch(nm.delete_prefix("n_")).length if nm.start_with?("n_")
    bufs.fetch(nm)
  end
  failure = nil
  answered = nil
  p0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    answered = doom_core_render(*args)
  rescue CoreFail, StandardError => e
    failure = "#{e.class}: #{e.message} at #{e.backtrace&.find { |b| b.include?('/core/src/') }}"
  end
  port_seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - p0
  r.clear_screen if t.zero?
  r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
  if SCALE == 1
    sb.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo, g.pl_weaponowned, g.pl_readyweapon, ak)
  else
    sb.draw(SHADOW, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo, g.pl_weaponowned, g.pl_readyweapon, ak)
    Doom::Hires.blit_scale(r.screen, 320 * SCALE, SHADOW, 320, 0, 168, 320, 32, SCALE)
  end
  hud.draw(r.screen)
  frames += 1

  lines = []
  uncovered.each do |f|
    next if value_of(f) == before[f]
    lines << "#{f} changed in the original, and the port does not take it"
    disagreed[f] += 1
  end
  if !failure && (answered != frames || state[FRAME_SLOT] != frames)
    lines << "doom_core_render answered #{answered.inspect} and counted #{state[FRAME_SLOT]}; this is frame #{frames}"
  end
  if failure
    lines << "raised #{failure}"
    errors[failure[/\A[^ ]+ [^ ]+/]] += 1
  else
    lines << "status bar shadow #{diff(bufs['sb_shadow'], SHADOW, 'sb_shadow')}" if bufs["sb_shadow"] != SHADOW.bytes
    buffer_field.each do |name, field|
      next if EXCLUDED.include?(field) || ROLE[field] == "resource"
      d = diff(bufs[name], value_of(field), field) or next
      lines << "#{field} #{d}"
      disagreed[field] += 1
    end
    all_slots.each_with_index do |f, k|
      next if EXCLUDED.include?(f)
      o = port_cell(value_of(f), f)
      next if state[k] == o
      lines << "#{f} port #{state[k].inspect} original #{o.inspect}"
      disagreed[f] += 1
    end
  end
  next if lines.empty?
  bad += 1
  puts "tic #{t}: #{lines.length} disagreement(s)"
  lines.first(12).each { |l| puts "  #{l}" }
  if bad >= stop_after
    puts "stopped after #{bad} disagreeing frame(s)"
    n = t + 1
    break
  end
end
resource_bad = []
(resource_copy || {}).each do |name, copy|
  d = diff(copy, value_of(buffer_field[name]), buffer_field[name]) or next
  resource_bad << "#{buffer_field[name]} #{d}"
end
puts "render-diff: #{(resource_copy || {}).size} resource buffer(s) checked at the end: #{resource_bad.size} changed"
resource_bad.each { |l| puts "  #{l}" }
bad += 1 unless resource_bad.empty?
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "render-diff: #{demo_name} #{frames} frame(s), #{bad} disagreeing; #{disagreed.size} field(s) disagreed: " \
     "#{disagreed.sort_by { |k, v| [-v, k] }.first(30).map { |k, v| "#{k}x#{v}" }.join(' ')}"
puts "render-diff: #{errors.size} distinct error(s): #{errors.map { |k, v| "#{k} x#{v}" }.join('; ')}"
printf("render-diff: %.1f s wall, %.3f s in the port (%.1f ms/frame)\n", wall, port_seconds, 1000.0 * port_seconds / frames)
if cov_path
  res = Coverage.result.select { |f, _| f.start_with?(src) }.to_h { |f, v| [File.basename(f), v[:lines]] }
  File.write(cov_path, JSON.generate(res))
end
exit(bad.zero? ? 0 : 1)
