# frozen_string_literal: true
#
# tests/doom-core/step-diff.rb — the step port against the original, one tic at a time.
#
#   ruby tests/doom-core/step-diff.rb WAD DEMO TICS [--stop-after N] [--src DIR]
#
# --src loads the port from another directory: how a control runs a planted
# defect without touching the tree; a planted defect must change a VALUE,
# not only the text (see source-port.rb's poison rule). --coverage FILE writes the port's line
# coverage (Ruby's Coverage, lines mode) as JSON, so a run says which of the
# port's lines it exercised -- an agreement says nothing about a line no tic ran.
#
# THE STEP ENTRY AGAINST THE ORIGINAL LOOP. It runs doom_core_step
# (examples/doom/core/src/doomentry.rb) against what the program's loop does
# for a tic: the melt wipe's draws at tic 2, g_ticker, the ST_Ticker draw
# (M_Random), the status bar's ticker with the values the loop hands it,
# take_message and the HUD's ticker. Before each tic it copies the original
# game's state into the entry's layout -- every buffer the entry takes, resolved
# through examples/doom/core/entries/fields.tsv, and every scalar field through
# step-slots.tsv's index table -- calls the entry on the copy and runs the
# original loop's code on the game, and compares every field after, and the
# gametic the entry answers. The copy is made afresh each tic, so a defect
# shows at the tic that reaches it and does not bury the ones after it; the
# original alone carries the game forward.
#
# It runs the port in CRuby, not the kernel's object: what it measures is
# whether the port's code computes the original's values. Whether the kernel
# compiles that code faithfully is a separate check (the native routes).
#
# It prints, per tic, the fields that disagree (a field's first differing cell,
# and how many), or the error the port raised; and at the end the distinct
# fields that disagreed anywhere and the tics per second. It answers 0 when
# every tic agreed.
ROOT = File.expand_path("../..", __dir__)
%w[wad level texnames texture sprites statusbar hud render info random demo game bytes hires].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }

wad_path, demo_name, ntics = ARGV[0], ARGV[1], ARGV[2].to_i
stop_after = (i = ARGV.index("--stop-after")) ? ARGV[i + 1].to_i : 20
wad_path && demo_name && ntics.positive? or abort("usage: step-diff.rb WAD DEMO TICS [--stop-after N]")

# --- the port, loaded as plain Ruby ---------------------------------------------
cov_path = (i = ARGV.index("--coverage")) ? ARGV[i + 1] : nil
if cov_path
  require "coverage"
  require "json"
  Coverage.start(lines: true)
end
require File.join(ROOT, "examples/doom/core/full/session")
# FULL'S PRE-STEP CONDITION (Doom::Core::Session#before_step!): a pending
# rebirth is refused before doom_core_step is called, as the shipped program
# does. --no-full-guard calls the entry anyway, which is how CORE's backstop
# refusal is shown.
FULL_GUARD = !ARGV.delete("--no-full-guard")
# THE PORT HOLDS ANGLES AS SIGNED PATTERNS (decision 0022 section 2.4): the
# angle buffers and slots examples/doom/core/full/reference.rb names are
# handed in, and compared, as the original's words converted the same way.
# --raw-repr hands them in unconverted, the planted control that shows the
# conversion is needed.
require File.join(ROOT, "examples/doom/core/full/reference")
RAW_REPR = ARGV.delete("--raw-repr")
class CoreFail < StandardError; end
def core_fail(what) = raise(CoreFail, "core_fail(#{what.inspect})")
src = (i = ARGV.index("--src")) ? ARGV[i + 1] : File.join(ROOT, "examples/doom/core/src")
# where a refusal happened is the port's frame nearest it, in whichever source
# directory the port was loaded from
SRC_DIR = File.expand_path(src) + "/"
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
File.readlines(File.join(ROOT, "examples/doom/core/sources.tsv"))
    .reject { |l| l.start_with?("#") || l.strip.empty? }
    .each { |l| load File.join(src, l.split("\t").first) }

# --- the original ---------------------------------------------------------------
wad = Doom::Wad.new(wad_path)
# `scenario:NAME` in place of a demo: tests/doom-core/scenarios.rb's synthesised
# start -- its level, skill and length, its setup through the original's own
# methods, and the commands its key script makes -- with the port definitions
# it must enter.
SCENARIO = demo_name.start_with?("scenario:") ? demo_name.delete_prefix("scenario:") : nil
if SCENARIO
  require "tmpdir"
  require File.join(ROOT, "tests/doom-core/scenarios")
  sc = Scenarios::ALL.fetch(SCENARIO) { abort("step-diff: no scenario #{SCENARIO}") }
  cmds = Scenarios.commands(sc)
  ep, mp = sc[:map].scan(/\d/).map(&:to_i)
  demo = Struct.new(:mapname, :episode, :map, :skill, :numtics, :forwardmove, :sidemove, :angleturn, :buttons)
               .new(sc[:map], ep, mp, sc[:skill], sc[:tics], cmds.map { |c| c[0] }, cmds.map { |c| c[1] },
                    cmds.map { |c| c[2] }, cmds.map { |c| c[3] })
else
  demo = Doom::Demo.new(wad, demo_name, "")
end
lv = Doom::Level.new(wad, demo.mapname, demo.episode)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
sc[:setup]&.call(g) if SCENARIO
sb = Doom::StatusBar.new(wad)
sb.start(g.pl_weaponowned)
hud = Doom::Hud.new(wad, 320, 200, 1)
OWNERS = { "Game" => g, "Level" => lv, "Random" => rnd, "Textures" => tx, "StatusBar" => sb, "Hud" => hud }.freeze

# --- the layout -----------------------------------------------------------------
FIELDS = {}
File.foreach(File.join(ROOT, "examples/doom/core/state.tsv")) do |l|
  next if l.start_with?("#")
  f = l.chomp.split("\t")
  FIELDS[f[0]] = f[5] # origin, Class@@ivar
end
PREFIXES = %w[game level textures random].freeze
def origin_of(field)
  o = FIELDS.fetch(field) { abort("step-diff: no field #{field}") }
  cls, ivar = o.split("@@", 2)
  owner = OWNERS.fetch(cls) { abort("step-diff: #{field} belongs to #{cls}, which this harness does not hold") }
  [owner, "@#{ivar}"]
end
def value_of(field)
  owner, ivar = origin_of(field)
  owner.instance_variable_get(ivar)
end
def cell(v) = v == true ? 1 : (v == false ? 0 : v)

# THE ENTRY'S OWN SIGNATURE AND FIELD MAP (examples/doom/core/entries/fields.tsv):
# every buffer doom_core_step takes, by the field it is. The added fields --
# the command, the work stacks, the capacity cells -- are the harness's to fill.
sig = File.read(File.join(src, "doomentry.rb"))[/^def doom_core_step\(([^)]*)\)/m, 1].split(",").map(&:strip)
ENTRY_FIELD = File.readlines(File.join(ROOT, "examples/doom/core/entries/fields.tsv"))
                  .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }
                  .select { |f| f[0] == "doom_core_step" }.to_h { |f| [f[1], f[2]] }
ADDED = %w[core_state core_command core_knot_stack core_sight_stack core_sound_stack core_step_caps].freeze
buffer_field = ENTRY_FIELD.reject { |_, f| ADDED.include?(f) || f.start_with?("derived:") }
slot_fields = File.readlines(File.join(ROOT, "examples/doom/core/entries/step-slots.tsv"))
                  .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t")[2] }
held = ->(f) { OWNERS.key?(FIELDS.fetch(f).split("@@").first) }
RNDBYTES = Doom::Random::RNDTABLE.bytes.freeze
# EVERY OTHER FIELD THE HARNESS HOLDS must not change in the original's tic: a
# field the original writes and the port does not take would otherwise be a
# write nobody compares.
covered = buffer_field.values | slot_fields
# (a field whose origin is not a plain instance variable -- an alias into
# another object's storage -- is not read here)
plain = ->(f) { FIELDS.fetch(f).split("@@", 2)[1].to_s.match?(/\A[a-z_][a-z0-9_]*\z/) }
uncovered = FIELDS.keys.select { |f| held.(f) && plain.(f) && !covered.include?(f) }
                  .reject { |f| (v = value_of(f)).nil? || !(v.is_a?(Array) || v.is_a?(String) || v.is_a?(Integer) || v == true || v == false) }

# The knot stack's declared capacity, in frames of 21 cells. `--knot-frames N`
# is how the capacity contract is witnessed (decision 0008's clarification):
# below the capacity execution agrees with the reference, and at the capacity
# the entry refuses deterministically without writing past it. The default is
# the shipping configuration.
KNOT_FRAMES = (i = ARGV.index("--knot-frames")) ? Integer(ARGV[i + 1], 10) : 256
KS_CELLS = 21 * KNOT_FRAMES
nodes = lv.instance_variable_get(:@num_nodes)
sectors = lv.instance_variable_get(:@num_sectors)
SIGHT = 3 * (nodes + 1)
SOUND = 6 * (sectors + 1)
switches = g.instance_variable_get(:@switchlist).length

# a buffer's port copy: an array of integers
def copy_in(v)
  case v
  when Array then v.map { |x| cell(x) }
  when String then v.bytes
  when Integer, true, false then [cell(v)]
  else abort("step-diff: a field holds #{v.class}")
  end
end
# a field's cells as the port holds them
def port_cells(v, field)
  c = copy_in(v)
  return c if RAW_REPR || !Doom::Core::Reference.i32_bits?(field)

  c.map { |x| Doom::Core::Reference.pattern(x) }
rescue Doom::Core::Reference::ReferenceError => e
  abort("step-diff: #{field}: #{e.message}")
end
# a slot cell as the port holds it
def port_cell(v, field)
  c = cell(v)
  return c if RAW_REPR || !Doom::Core::Reference.i32_bits?(field)

  Doom::Core::Reference.pattern(c)
rescue Doom::Core::Reference::ReferenceError => e
  abort("step-diff: #{field}: #{e.message}")
end
# A held field's value as it stands, for "unchanged": a copy, not a conversion.
def snap(v) = v.is_a?(Array) ? v.map { |x| x.is_a?(String) ? x.dup : x } : (v.is_a?(String) ? v.dup : v)

def diff(port, v, field)
  orig = port_cells(v, field)
  return nil if port == orig
  n = [port.length, orig.length].max
  i = (0...n).find { |k| port[k] != orig[k] }
  count = (0...n).count { |k| port[k] != orig[k] }
  "cell #{i}: port #{port[i].inspect} original #{orig[i].inspect} (#{count} cell(s))"
end

TARGETS = SCENARIO ? sc[:targets] : []
entered = Hash.new(0)
tracer = TracePoint.new(:call) { |tp| entered[tp.method_id.to_s] += 1 if TARGETS.include?(tp.method_id.to_s) }
stopped = nil
disagreed = Hash.new(0)
errors = Hash.new(0)
bad_tics = 0
n = [ntics, demo.numtics].min
puts "step-diff: #{buffer_field.size} buffer(s) and #{slot_fields.count { |f| held.(f) }} slot(s) compared; " \
     "#{uncovered.size} other held field(s) required unchanged"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
port_seconds = 0.0
ks_after = []   # the knot stack as the last tic left it; see the overrun check below
n.times do |t|
  rnd.tic = t
  # the loop's own draws are the entry's too: the copy is taken BEFORE the wipe's
  # 320 draws, and doom_core_step makes them first (`predraws`)
  bufs = buffer_field.to_h { |name, field| [name, port_cells(value_of(field), field)] }
  state = slot_fields.map { |f| held.(f) ? port_cell(value_of(f), f) : 0 }
  gx = (0...slot_fields.length).to_a
  bufs["cmd"] = [demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t], 0]
  bufs["ks"] = Array.new(KS_CELLS, 0)
  bufs["kn_caps"] = [0, 0, 0]
  bufs["sight_stack"] = Array.new(SIGHT, 0)
  bufs["sound_stack"] = Array.new(SOUND, 0)
  scal = { "predraws" => t == 2 ? 320 : 0 }
  args = sig.map do |nm|
    next state if nm == "state"
    next gx if nm == "gx"
    next scal[nm] if scal.key?(nm)
    next (nm.delete_prefix("n_") == "state" ? state : nm.delete_prefix("n_") == "gx" ? gx : bufs.fetch(nm.delete_prefix("n_"))).length if nm.start_with?("n_")
    bufs.fetch(nm)
  end
  before = uncovered.to_h { |f| [f, snap(value_of(f))] }
  ks_after = bufs["ks"]   # the same Array the port was handed this tic
  failure = nil
  answered = nil
  p0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  full_refused = FULL_GUARD && Doom::Core::Session.rebirth_pending?(state[G_PL_PLAYERSTATE])
  begin
    tracer.enable if SCENARIO && !full_refused
    answered = doom_core_step(*args) unless full_refused
  rescue CoreFail, StandardError => e
    failure = "#{e.class}: #{e.message} at #{e.backtrace&.find { |b| b.start_with?(SRC_DIR) }}"
  ensure
    tracer.disable
  end
  port_seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - p0

  if t == 2
    320.times { rnd.m_random }
  end
  begin
    g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
  rescue Doom::LevelError => e
    # THE ORIGINAL STOPPED. Only a `stops` scenario may reach this, and the port
    # must have refused at this same tic; the run ends here either way.
    stopped = [t, e.message]
    where = failure.to_s[/ at (.*)\z/, 1].to_s
    if full_refused && SCENARIO && sc[:full_refuses]
      puts "tic #{t}: Full refused before the call -- the original raised #{e.message.inspect}, and doom_core_step was not entered"
    elsif SCENARIO && sc[:stops] && failure&.include?("core_fail(:capacity)") && where.include?("#{sc[:stop_in]}'")
      puts "tic #{t}: both stopped -- the original raised #{e.message.inspect}, the port refused with #{failure[/core_fail\(:\w+\)/]}"
    else
      puts "tic #{t}: the original raised #{e.message.inspect} and the port #{failure ? "raised #{failure}, not in #{sc && sc[:stop_in]}" : 'did not stop'}"
      bad_tics += 1
    end
    n = t + 1
    break
  end
  st_randomnumber = rnd.m_random
  m = g.player_mo
  atk = g.pl_attacker
  kind = atk < 0 ? Doom::StatusBar::ATTACKER_NONE :
         (atk == m ? Doom::StatusBar::ATTACKER_SELF : Doom::StatusBar::ATTACKER_OTHER)
  bga = atk >= 0 ? g.point_to_angle2(g.mobj_x[m], g.mobj_y[m], g.mobj_x[atk], g.mobj_y[atk]) : 0
  sb.ticker(st_randomnumber, g.pl_health, g.pl_weaponowned, g.pl_cards,
            g.pl_damagecount, g.pl_bonuscount, g.pl_attackdown,
            g.pl_powers[0], kind, bga, g.mobj_angle[m])
  hud.ticker(g.take_message)
  lines = []
  uncovered.each do |f|
    next if value_of(f) == before[f]
    lines << "#{f} changed in the original, and the port does not take it"
    disagreed[f] += 1
  end
  if full_refused
    lines << "Full refused a rebirth before the call, and the original did not stop"
  elsif !failure && answered != g.gametic
    lines << "doom_core_step answered #{answered.inspect}, the gametic is #{g.gametic}"
  end
  if failure
    lines << "raised #{failure}"
    errors[failure[/\A[^ ]+ [^ ]+/]] += 1
  else
    buffer_field.each do |name, field|
      d = diff(bufs[name], value_of(field), field) or next
      lines << "#{field} #{d}"
      disagreed[field] += 1
    end
    slot_fields.each_with_index do |f, i|
      next unless held.(f)
      o = port_cell(value_of(f), f)
      next if state[i] == o
      lines << "#{f} port #{state[i].inspect} original #{o.inspect}"
      disagreed[f] += 1
    end
  end
  next if lines.empty?
  bad_tics += 1
  puts "tic #{t}: #{lines.length} disagreement(s)"
  lines.first(12).each { |l| puts "  #{l}" }
  if bad_tics >= stop_after
    puts "stopped after #{bad_tics} disagreeing tic(s)"
    n = t + 1
    break
  end
end
if SCENARIO
  missing = TARGETS.reject { |d| entered[d].positive? }
  puts "step-diff: scenario #{SCENARIO} entered #{TARGETS.map { |d| "#{d}=#{entered[d]}" }.join(' ')}"
  unless missing.empty?
    puts "step-diff: scenario #{SCENARIO} never entered #{missing.join(', ')}"
    bad_tics += 1
  end
  if sc[:stops] && stopped.nil?
    puts "step-diff: scenario #{SCENARIO} was to stop, and the original ran all #{n} tic(s)"
    bad_tics += 1
  end
end
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "step-diff: #{demo_name} #{n} tic(s), #{bad_tics} disagreeing; " \
     "#{disagreed.size} field(s) disagreed: #{disagreed.sort_by { |k, v| [-v, k] }.map { |k, v| "#{k}x#{v}" }.join(' ')}"
puts "step-diff: #{errors.size} distinct error(s): #{errors.map { |k, v| "#{k} x#{v}" }.join('; ')}"
# THE OVERRUN CHECK, and it is the Array itself: a write past the end would
# GROW it, so a length still equal to the declared capacity is the evidence
# that nothing was written past it.
puts "step-diff: knot stack #{KNOT_FRAMES} frame(s) = #{KS_CELLS} cell(s) declared, " \
     "#{ks_after.length} cell(s) after the run#{ks_after.length == KS_CELLS ? '' : ' -- WRITTEN PAST THE END'}"
printf("step-diff: %.1f s wall, %.3f s in the port (%.1f ms/tic)\n", wall, port_seconds, 1000.0 * port_seconds / n)
if cov_path
  res = Coverage.result.select { |f, _| f.start_with?(src) }.to_h { |f, v| [File.basename(f), v[:lines]] }
  File.write(cov_path, JSON.generate(res))
end
exit(bad_tics.zero? ? 0 : 1)
