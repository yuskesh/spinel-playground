# frozen_string_literal: true
#
# tests/doom-core/input-diff.rb — the input entry against the original, one tic at a time.
#
#   ruby tests/doom-core/input-diff.rb [--tics N] [--seed S] [--src DIR] [--entries DIR]
#
# step-diff.rb's twin for doom_core_input (examples/doom/core/src/doomentry.rb).
# The original is bin/doom.rb's input step: with a key script, KeyScript#apply
# then TiccmdBuilder#build; without one, the polled keys then #build; with
# recording, #quantize_angle! and DemoWriter#write_tic. Before each tic the
# original's state is copied into the entry's layout -- every buffer through
# examples/doom/core/entries/fields.tsv, every scalar through input-slots.tsv --
# the entry runs on the copy, the original runs on itself, and every field is
# compared after, with the command the entry publishes: forward, side, turn and
# buttons as #build leaves them, and the angle byte #quantize_angle! answers
# (computed the same way from the unquantized turn when not recording, which is
# what 0008's fifth cell is).
#
# FOUR RUNS: scripted or polled, recording or not. A scripted run's script and a
# polled run's keys are drawn from a seeded generator over every key #build
# reads and some it does not, so the strafe, speed, turn-acceleration and
# weapon paths are all taken. A FIFTH RUN fills the demo buffer: the original
# raises at the tic its buffer is full, and the entry must refuse at that same
# tic with CAPACITY. And a four-cell command buffer is refused.
#
# It runs the port in CRuby, like step-diff.rb; --src loads it from another
# directory, which is how a control plants a defect (a planted defect must change
# a VALUE, not only the text). It answers 0 when every tic of every run agreed.
ROOT = File.expand_path("../..", __dir__)
require File.join(ROOT, "examples/doom/lib/doom/input")
require File.join(ROOT, "examples/doom/lib/doom/record")
require "tmpdir"

arg = ->(name, default) { (i = ARGV.index(name)) ? ARGV[i + 1] : default }
TICS = Integer(arg.("--tics", "400"), 10)
SEED = Integer(arg.("--seed", "7"), 10)
src = arg.("--src", File.join(ROOT, "examples/doom/core/src"))
# --entries reads the field map and the slot table from another directory: a
# control's swapped table
entries = arg.("--entries", File.join(ROOT, "examples/doom/core/entries"))

class CoreFail < StandardError; end
def core_fail(what) = raise(CoreFail, "core_fail(#{what.inspect})")
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
File.readlines(File.join(ROOT, "examples/doom/core/sources.tsv"))
    .reject { |l| l.start_with?("#") || l.strip.empty? }
    .each { |l| load File.join(src, l.split("\t").first) }

sig = File.read(File.join(src, "doomentry.rb"))[/^def doom_core_input\(([^)]*)\)/m, 1].split(",").map(&:strip)
ENTRY_FIELD = File.readlines(File.join(entries, "fields.tsv"))
                  .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }
                  .select { |f| f[0] == "doom_core_input" }.to_h { |f| [f[1], f[2]] }
SLOTS = File.readlines(File.join(entries, "input-slots.tsv"))
            .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t")[2] }
ORIGIN = {}
File.foreach(File.join(ROOT, "examples/doom/core/state.tsv")) do |l|
  next if l.start_with?("#")
  f = l.chomp.split("\t")
  ORIGIN[f[0]] = f[5]
end

# the keys #build reads, and three it does not
KEYS = Doom::TiccmdBuilder::WATCHED_KEYS + [65, 0x80, 13]
NAMES = Doom::Keys::NAMES.keys

def cells(v) = v.is_a?(String) ? v.bytes : (v.is_a?(Array) ? v : [v]).map { |x| x == true ? 1 : (x == false ? 0 : x) }

total_bad = 0
summary = []
run = lambda do |label, scripted, recording, tics, maxtics|
  rng = Random.new(SEED + (scripted ? 1 : 0) + (recording ? 2 : 0) + maxtics)
  script = nil
  if scripted
    path = File.join(Dir.mktmpdir("input-diff"), "s.txt")
    lines = Array.new(60) do
      a = rng.rand(tics)
      "#{a} #{a + rng.rand(40)} #{Array.new(1 + rng.rand(3)) { NAMES.sample(random: rng) }.uniq.join(',')}"
    end
    File.write(path, lines.join("\n") + "\n")
    script = Doom::KeyScript.new(path)
  end
  ks = Doom::KeyState.new
  tc = Doom::TiccmdBuilder.new
  rec = Doom::DemoWriter.new(2, 1, 1, maxtics)
  objects = { "KeyState" => ks, "TiccmdBuilder" => tc, "DemoWriter" => rec, "KeyScript" => script }
  value = lambda do |field|
    cls, ivar = ORIGIN.fetch(field).split("@@", 2)
    objects.fetch(cls).instance_variable_get("@#{ivar}")
  end
  bad = 0
  refused_at = nil
  raised_at = nil
  tics.times do |t|
    # Full's side: a polled tic stores the keys it read
    unless scripted
      ks.clear
      KEYS.each { |k| ks.press(k) if rng.rand(5).zero? }
    end
    bufs = ENTRY_FIELD.reject { |_, f| f == "core_state" || f.start_with?("derived:") || f.start_with?("core_") }
                      .to_h { |name, field| [name, (scripted || !name.start_with?("script_")) ? cells(value.(field)) : [0]] }
    bufs["cmd"] = [0, 0, 0, 0, 0]
    state = SLOTS.map { |f| cells([value.(f)]).first }
    xi = (0...SLOTS.length).to_a
    scal = { "scripted" => scripted ? 1 : 0, "tic" => t, "recording" => recording ? 1 : 0 }
    args = sig.map do |nm|
      next state if nm == "state"
      next xi if nm == "xi"
      next scal[nm] if scal.key?(nm)
      next (nm == "n_state" ? state : nm == "n_xi" ? xi : bufs.fetch(nm.delete_prefix("n_"))).length if nm.start_with?("n_")
      bufs.fetch(nm)
    end
    failure = nil
    begin
      doom_core_input(*args)
    rescue CoreFail => e
      failure = e.message
    end
    # the original loop's input step
    original_error = nil
    byte = nil
    begin
      script.apply(ks, t) if scripted
      tc.build(ks.down)
      if recording
        byte = tc.quantize_angle!
        rec.write_tic(tc.forwardmove, tc.sidemove, byte, tc.buttons)
      else
        byte = ((tc.angleturn + 128) >> 8) & 0xff
      end
    rescue Doom::Error => e
      original_error = e.message
    end
    lines = []
    if failure || original_error
      if failure && original_error
        refused_at ||= t
        raised_at ||= t
        break
      end
      lines << "entry: #{failure.inspect}, original: #{original_error.inspect}"
    else
      want = [tc.forwardmove, tc.sidemove, tc.angleturn, tc.buttons, byte]
      lines << "cmd #{bufs['cmd'].inspect} original #{want.inspect}" unless bufs["cmd"] == want
      ENTRY_FIELD.each do |name, field|
        next if field == "core_state" || field.start_with?("derived:") || field.start_with?("core_")
        next if name.start_with?("script_") && !scripted
        o = cells(value.(field))
        next if bufs[name] == o
        k = (0...[o.length, bufs[name].length].max).find { |x| bufs[name][x] != o[x] }
        lines << "#{field} cell #{k}: entry #{bufs[name][k].inspect} original #{o[k].inspect}"
      end
      SLOTS.each_with_index do |f, k|
        o = cells([value.(f)]).first
        lines << "#{f} entry #{state[k]} original #{o}" unless state[k] == o
      end
    end
    next if lines.empty?
    bad += 1
    puts "#{label} tic #{t}: #{lines.first(6).join('; ')}" if bad <= 10
  end
  summary << "#{label} #{tics} tic(s) #{bad} disagreeing" \
             "#{refused_at ? ", both refused at tic #{refused_at}" : ''}"
  [bad, refused_at]
end

[[false, false], [true, false], [false, true], [true, true]].each do |scripted, recording|
  b, = run.("#{scripted ? 'scripted' : 'polled'}-#{recording ? 'recording' : 'playing'}", scripted, recording, TICS, TICS + 1)
  total_bad += b
end
# the demo buffer fills at tic 50 of 60
b, at = run.("capacity", true, true, 60, 50)
total_bad += b
unless at == 50
  puts "capacity: the entry and the original did not both refuse at tic 50 (#{at.inspect})"
  total_bad += 1
end
# A COMMAND BUFFER SHORTER THAN 0008's FIVE CELLS is refused before anything
# is written.
short = sig.map do |nm|
  case nm
  when "state" then [0] * SLOTS.length
  when "xi" then (0...SLOTS.length).to_a
  when "cmd" then [0, 0, 0, 0]
  when "scripted", "tic", "recording" then 0
  when "down" then [0] * 256
  when "demo_max" then [1]
  when /\An_(.*)\z/ then { "state" => SLOTS.length, "xi" => SLOTS.length, "cmd" => 4, "down" => 256 }.fetch($1, 1)
  else [0]
  end
end
begin
  doom_core_input(*short)
  puts "short-command: the entry accepted a four-cell command buffer"
  total_bad += 1
rescue CoreFail => e
  summary << "short-command refused (#{e.message})"
end
summary.each { |l| puts "input-diff: #{l}" }
puts "input-diff: #{total_bad.zero? ? 'every run agreed' : "#{total_bad} disagreement(s)"}"
exit(total_bad.zero? ? 0 : 1)
