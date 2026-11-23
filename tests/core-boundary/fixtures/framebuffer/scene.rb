# frozen_string_literal: true
#
# The original Full job executor, answering for itself -- on every byte.
#
# Decision 0007 task 5 asks for the wall, span and fuzz framebuffer operations
# to be compared with the original, byte for byte, with the schedule order
# preserved and the neighbouring access exercised. So no expected screen is
# written down anywhere. This script
#
#   1. builds the resources and the initial screen from the seed in scene.tsv,
#   2. runs `Doom::JobExecutor`'s OWN exec_wall / exec_span / exec_masked over
#      the schedule, UNMODIFIED, and keeps the screen it produces,
#   3. runs the extracted Ruby over the same schedule into a second screen,
#   4. refuses to emit anything unless those two agree on every byte, and
#   5. writes the resources, the schedule and the original's screen out for
#      the C harness, which calls the CORE kernels and compares.
#
# THE ORIGINAL IS DRIVEN, NOT TRANSCRIBED. `JobExecutor#initialize` wants a
# `Doom::Jobs` bank object and renderer-shaped resources, and building one here
# would mean reproducing the renderer. But the three methods read only ivars,
# so the object is `allocate`d and the ivars are set directly. What runs is the
# method body in examples/doom/lib/doom/executor.rb, character for character;
# a change to it that the extraction did not follow shows up as a mismatch.
#
# THERE IS NO C REFERENCE. The C harness computes nothing: it parses this
# file's output, calls the kernels, and compares. The expected bytes are the
# original Ruby's, so no C allowance can stand between Full and CORE.
#
# usage: scene.rb <repo-root> <fixtures-dir> <out-file>
#
# The fixture directory is a separate argument so a MUTATED COPY of it can be
# driven by the same script: the lane's controls change one line of an
# extracted source and require this comparison to fail. The repository root
# still names the original, which is never copied.

root = ARGV[0] or abort("scene: the repository root is required")
fixtures = ARGV[1] or abort("scene: the fixture directory is required")
out = ARGV[2] or abort("scene: an output path is required")

$LOAD_PATH.unshift(File.join(root, "examples", "doom", "lib"))
require "doom/executor"

# Each extracted source defines `M32` for itself, because each is the root of
# its own CORE build and may not depend on a neighbour to have been loaded.
# Under CRuby they land in one namespace, so the second definition warns. The
# warning is silenced only across the loads, and the value is checked
# afterwards, so silencing it cannot hide two sources disagreeing about it.
verbose = $VERBOSE
$VERBOSE = nil
Dir[File.join(fixtures, "src", "*.rb")].sort.each { |f| load f }
$VERBOSE = verbose
abort("scene: the extracted sources disagree about M32") if M32 != 0xffffffff

# `R_DrawFuzzColumn`'s table, the 50 entries of +-1 that pick the row above or
# below. Copied from examples/doom/lib/doom/render.rb, which took it from
# DG/r_draw.c. It is data, not a rule, so it is repeated here rather than
# reached for through the renderer.
FUZZOFFSET = [
  1, -1, 1, -1, 1, 1, -1,
  1, 1, -1, 1, 1, 1, -1,
  1, 1, 1, -1, -1, -1, -1,
  1, -1, -1, 1, 1, 1, 1, -1,
  1, -1, 1, 1, -1, -1, 1,
  1, -1, -1, -1, -1, 1, 1,
  1, 1, -1, 1, 1, -1, 1
].freeze
abort("scene: fuzzoffset must hold 50 entries, not #{FUZZOFFSET.length}") if FUZZOFFSET.length != 50

# ---- the scene ------------------------------------------------------------

# Every record is consumed or refused, and every column of every record is
# consumed or refused, because a column this reads past would be one the table
# carries and nothing acts on -- the same rule the C harness applies to the
# scene it is handed. The column counts are declared here so a row with one
# too many is a diagnostic rather than a value quietly dropped.
KINDS = %w[wall span fuzz].freeze
STATUSES = (0..4).to_a.freeze   # decision 0007: OK, ARGUMENT, ARITHMETIC, BOUNDS, CAPACITY
RESOURCES = %w[atlas flat cmap].freeze
WIDTHS = { "frame" => 6, "seed" => 2, "res" => 3, "job" => 9, "check" => 11 }.freeze

frame = nil
seed = nil
sizes = {}
schedule = []
checks = []
lineno = 0
File.readlines(File.join(fixtures, "scene.tsv"), chomp: true).each do |line|
  lineno += 1
  next if line.start_with?("#") || line.strip.empty?
  f = line.split("\t", -1)
  where = "scene.tsv line #{lineno}"
  want = WIDTHS[f[0]] or abort("scene: #{where} has an unknown record #{f[0].inspect}")
  abort("scene: #{where} is a #{f[0]} record with #{f.length} columns, not #{want}") if f.length != want
  num = ->(s) { s == "-" ? 0 : (Integer(s, 10) rescue abort("scene: #{where} holds #{s.inspect}, which is not a number")) }
  case f[0]
  when "frame"
    abort("scene: #{where} declares the frame a second time") if frame
    frame = f[1, 5].map(&num)
  when "seed"
    abort("scene: #{where} declares the seed a second time") if seed
    seed = num.call(f[1])
  when "res"
    abort("scene: #{where} names a resource this scene has no use for") unless RESOURCES.include?(f[1])
    abort("scene: #{where} declares #{f[1]} a second time") if sizes.key?(f[1])
    sizes[f[1]] = num.call(f[2])
  when "job"
    schedule << [f[1], f[2, 7].map(&num)]
  # Passed through to the C harness untouched. They are the ABI's cases, not
  # CRuby's, so nothing here runs them; see scene.tsv for why.
  when "check"
    checks << [f[1], f[2, 7].map(&num), num.call(f[9])]
  end
end
abort("scene: scene.tsv declares no frame") if frame.nil?
abort("scene: scene.tsv declares no seed") if seed.nil?
abort("scene: scene.tsv declares no jobs") if schedule.empty?
abort("scene: scene.tsv declares no ABI checks") if checks.empty?
(schedule + checks).each do |kind, _, _|
  abort("scene: scene.tsv has an unknown job kind #{kind.inspect}") unless KINDS.include?(kind)
end
checks.each do |kind, _, st|
  abort("scene: a #{kind} check wants status #{st}, which is not one of the ABI's") unless STATUSES.include?(st)
end
RESOURCES.each { |n| sizes[n] or abort("scene: scene.tsv declares no size for #{n}") }
abort("scene: the atlas must be whole 128-byte columns") unless (sizes["atlas"] % 128).zero?
abort("scene: the flat atlas must be whole 4096-byte flats") unless (sizes["flat"] % 4096).zero?
abort("scene: the colormap must be whole 256-byte rows") unless (sizes["cmap"] % 256).zero?

width, height, viewwindowx, viewwindowy, centery = frame
n_scr = width * height

# A plain LCG, written out here so the bytes are a property of this file and
# not of whatever Random happens to do. The resources are PSEUDO-RANDOM rather
# than constant or ramp-shaped on purpose: with a constant colormap or atlas,
# a kernel that computed the wrong index would still fetch the right byte, and
# the byte comparison would pass while the indexing was wrong.
def noise(n, seed)
  s = seed & 0x7fffffff
  Array.new(n) do
    s = (s * 1103515245 + 12345) & 0x7fffffff
    (s >> 16) & 0xff
  end
end

screen0 = noise(n_scr, seed)
atlas = noise(sizes["atlas"], seed + 1)
flat  = noise(sizes["flat"], seed + 2)
cmap  = noise(sizes["cmap"], seed + 3)

# ---- the original ---------------------------------------------------------

J = Doom::Jobs
wall_bank = []
span_bank = []
masked_bank = []
plan = []   # [kind, index-into-its-bank], in schedule order
schedule.each do |kind, v|
  case kind
  when "wall"
    i = wall_bank.length / J::WC_NF
    b = Array.new(J::WC_NF, 0)
    b[J::WC_X] = v[0]; b[J::WC_YL] = v[1]; b[J::WC_YH] = v[2]
    b[J::WC_ISCALE] = v[3]; b[J::WC_TEXMID] = v[4]
    b[J::WC_SRCOFS] = v[5]; b[J::WC_CMAP] = v[6]
    wall_bank.concat(b)
    plan << ["wall", i]
  when "span"
    i = span_bank.length / J::SP_NF
    b = Array.new(J::SP_NF, 0)
    b[J::SP_Y] = v[0]; b[J::SP_X1] = v[1]; b[J::SP_X2] = v[2]
    b[J::SP_POS] = v[3]; b[J::SP_STEP] = v[4]
    b[J::SP_SRCOFS] = v[5]; b[J::SP_CMAP] = v[6]
    span_bank.concat(b)
    plan << ["span", i]
  when "fuzz"
    i = masked_bank.length / J::MC_NF
    b = Array.new(J::MC_NF, 0)
    b[J::MC_X] = v[0]; b[J::MC_YL] = v[1]; b[J::MC_YH] = v[2]
    b[J::MC_FUZZ] = v[3]
    masked_bank.concat(b)
    plan << ["masked", i]
  else abort("scene: scene.tsv has an unknown job kind #{kind.inspect}")
  end
end

ex = Doom::JobExecutor.allocate
{
  "@wall" => wall_bank, "@span" => span_bank, "@masked" => masked_bank,
  "@colormap" => cmap.pack("C*"), "@atlas" => atlas.pack("C*"),
  "@flatatlas" => flat.pack("C*"), "@waddata" => +"", "@zonebuf" => +"",
  "@fuzzoffset" => FUZZOFFSET,
  "@width" => width, "@viewwindowx" => viewwindowx,
  "@viewwindowy" => viewwindowy, "@centery" => centery,
}.each { |k, v| ex.instance_variable_set(k.to_sym, v) }

original = screen0.pack("C*")
plan.each { |kind, i| ex.send(:"exec_#{kind}", i, original) }

# ---- the extraction -------------------------------------------------------

extracted = screen0.dup
schedule.each do |kind, v|
  case kind
  when "wall"
    draw_wall(extracted, extracted.length, atlas, atlas.length, cmap, cmap.length,
              v[1], v[2], v[5], v[6], v[3], v[4], v[0],
              width, viewwindowx, viewwindowy, centery)
  when "span"
    draw_span(extracted, extracted.length, flat, flat.length, cmap, cmap.length,
              v[1], v[2], v[0], v[5], v[6], v[3], v[4],
              width, viewwindowx, viewwindowy)
  when "fuzz"
    draw_fuzz(extracted, extracted.length, cmap, cmap.length,
              FUZZOFFSET, FUZZOFFSET.length,
              v[1], v[2], v[0], v[3], width, viewwindowx, viewwindowy)
  end
end

# ---- they must agree on every byte ----------------------------------------

abort("scene: the extraction grew the screen to #{extracted.length} of #{n_scr}") if extracted.length != n_scr
bad = (0...n_scr).select { |i| original.getbyte(i) != extracted[i] }
unless bad.empty?
  i = bad.first
  warn("scene: #{bad.length} byte(s) differ between the original and the extraction")
  warn("scene: first at #{i} (x=#{i % width} y=#{i / width}): " \
       "the original says #{original.getbyte(i)}, the extraction says #{extracted[i]}")
  exit(1)
end

# A schedule that changed nothing would make every comparison below vacuous.
drawn = (0...n_scr).count { |i| original.getbyte(i) != screen0[i] }
abort("scene: the schedule changed no pixel") if drawn.zero?

hex = ->(bytes) { bytes.map { |b| format("%02x", b) }.join }
File.open(out, "w") do |io|
  io.puts("# generated by scene.rb from scene.tsv -- do not edit")
  io.puts("frame #{width} #{height} #{viewwindowx} #{viewwindowy} #{centery}")
  io.puts("buf screen #{n_scr} #{hex.call(screen0)}")
  io.puts("buf atlas #{atlas.length} #{hex.call(atlas)}")
  io.puts("buf flat #{flat.length} #{hex.call(flat)}")
  io.puts("buf cmap #{cmap.length} #{hex.call(cmap)}")
  io.puts("i32 fuzzoffset #{FUZZOFFSET.length} #{FUZZOFFSET.join(' ')}")
  schedule.each { |kind, v| io.puts("job #{kind} #{v.join(' ')}") }
  checks.each { |kind, v, st| io.puts("check #{kind} #{v.join(' ')} #{st}") }
  io.puts("expect #{n_scr} #{hex.call(original.bytes)}")
end
warn("scene: #{schedule.length} job(s), #{n_scr} screen byte(s), #{drawn} changed by the schedule, " \
     "#{checks.length} ABI check(s) passed through")
