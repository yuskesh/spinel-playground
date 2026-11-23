# tests/doom-core/leaf-modes.rb — the renderer leaves' calls, digested, in one job mode.
#
#   ruby tests/doom-core/leaf-modes.rb --audit DIR [options] WAD DEMO TICS MODE
#
# WHY THIS EXISTS. The program's default is job mode 0: examples/doom/bin/doom.rb
# draws directly unless it is given -jobs. The leaf oracle -- source-port.rb
# running each ported leaf beside the original at every call -- runs in job
# mode 2, because its plane and push checks live there. THIS EQUALITY IS WHAT
# LETS THE ONE STAND FOR THE OTHER: if every leaf is called with the same
# arguments, returns the same result and leaves the same state in both modes,
# the mode-2 checks are checks of the stream the shipped default produces. It
# held before this file existed (measured over the three demos, 14.5 million
# calls) and nothing asserted it; a renderer change that made the modes diverge
# before a leaf call would have broken it silently. This is not a duplicate of
# the frame lane's checks: it compares the ORIGINAL with itself across modes,
# and runs no port at all. tests/doom-core/screens.sh runs it in both modes over
# every demo and requires the digests to agree.
#
# RETIRED WITH THE LANE IT SUPPORTS (0009's clarification of 2026-09-17). The
# leaf oracle this stands behind is one of the Stage-1 mixed lanes, so screens.sh
# runs this file only under STAGE1_LANES=run. THE EQUALITY IS STILL ASSERTED ON
# EVERY DEFAULT RUN, AT FRAME GRANULARITY, outside that block: screens.sh's "the
# recording does not depend on the job mode" replays a demo in job mode 2 and
# requires every frame to equal the job-mode-0 recording. What is asserted
# nowhere now is the per-call form below -- same arguments, same result, same
# state written, leaf by leaf -- and nothing live needs it while no lane runs a
# port in mode 2.
#
# MODE is 0 or 2, the renderer's job mode, selected the way sim_demo.rb selects
# it (`frame` and `frame,jobstat`). The output is one line per leaf --
# `leaf NAME calls N digest HEX` -- and a closing `leaf-modes` line. Two runs
# agree when those leaf lines are equal.
#
# WHAT A DIGEST HOLDS: for every call, the arguments, the result and the state
# the leaf wrote, marshalled. Only integers and integer arrays go in -- nothing
# a process seeds, such as #hash or an object id, which would make two runs of
# the same mode differ (that happened, in the measurement this file replaces).
#
# NOTHING HERE IS A LIST TO KEEP UP. The leaves are the definitions
# examples/doom/core/src/leaves.rb defines; every one must be reached from a leaf
# call source-port.rb makes (LEAF_CALLS, through the contract's entry wrapper),
# and every one must be named by a row of tools/doom/core-migrated.tsv, whose
# originals are what is wrapped here. What each original writes -- itself and
# through what it calls -- is read from the audit's state-use and closure
# tables. The one hand-written table is SLICES, which says how much of each
# written field a call can have touched; a written field without a slice, and a
# slice for a field no leaf writes, are both refused by name. So a leaf added to
# leaves.rb makes this check wider or makes it refuse; it cannot make it
# quietly narrower.
#
# Options:
#   --audit DIR        the audit build-artifacts.sh writes (state-use.tsv, closure.tsv)
#   --state-use FILE   another state-use table (a failing input)
#   --leaves FILE      another leaves.rb (a failing input)
#   --check            derive and refuse, then stop without running a demo
#   --break LEAF:N     after LEAF's Nth call, add one to the first visplane top
#                      cell: the input that must change the digests
require "digest"
require "optparse"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
PROG = "leaf-modes"
opt = { leaves: File.join(ROOT, "examples/doom/core/src/leaves.rb") }
OptionParser.new do |o|
  o.on("--audit DIR") { |v| opt[:audit] = v }
  o.on("--state-use FILE") { |v| opt[:state_use] = v }
  o.on("--leaves FILE") { |v| opt[:leaves] = v }
  o.on("--check") { opt[:check] = true }
  o.on("--break SPEC") { |v| opt[:break] = v }
end.parse!
def refuse(msg)
  warn "#{PROG}: #{msg}"
  exit 2
end
opt[:audit] or refuse("--audit DIR is required: the written fields are read from the audit")
state_use = opt[:state_use] || File.join(opt[:audit], "state-use.tsv")
closure = File.join(opt[:audit], "closure.tsv")
[state_use, closure, opt[:leaves]].each { |f| File.file?(f) or refuse("no file at #{f}") }
unless opt[:check]
  ARGV.length == 4 or refuse("usage: leaf-modes.rb --audit DIR [options] WAD DEMO TICS MODE")
  WHAT = { "0" => "frame", "2" => "frame,jobstat" }.fetch(ARGV[3]) { refuse("MODE is 0 or 2, not #{ARGV[3]}") }
end

# THE LEAVES: leaves.rb's definitions and the calls between them.
def defs_of(path)
  bodies = {}
  name = nil
  File.foreach(path) do |l|
    if (m = l.match(/\Adef (dc_\w+)/)) then name = m[1]; bodies[name] = +""
    elsif l.start_with?("end") then name = nil
    elsif name then bodies[name] << l
    end
  end
  bodies.transform_values { |b| b.scan(/\b(dc_\w+)\(/).flatten.uniq }
end
leaves = defs_of(opt[:leaves])
entries = defs_of(File.join(ROOT, "tests/doom-core/fixtures/source/src/entries.rb"))
leaf_calls = File.read(File.join(ROOT, "tests/doom-core/source-port.rb"))[/^LEAF_CALLS = %w\[([^\]]*)\]/, 1] or
  refuse("source-port.rb defines no LEAF_CALLS")
# A LEAF CALL WHOSE WORK DEPENDS ON THE JOB MODE BY CONSTRUCTION cannot have equal
# streams across modes, and is named here with the reason; it must reach nothing
# in leaves.rb, so a leaf cannot leave this check by being listed.
MODE_DEPENDENT = {
  "segloop" => "render_seg_loop (segs.rb) draws its wall columns in job mode 0 and pushes them in modes 1 " \
               "and 2, and sets @dc_srcbase only when queuing; its mode-2 path is the frame lane's per-call check"
}.freeze
reached = {}
leaf_calls.split.each do |c|
  contract = File.join(ROOT, "tests/doom-core/fixtures/source/#{c}.contract")
  entry = File.foreach(contract).map { |l| l[/\Aentry (\S+)/, 1] }.compact.first or refuse("#{contract} names no entry")
  stack = entries.fetch(entry) { refuse("#{entry} (#{c}) has no wrapper in entries.rb") } & leaves.keys
  if MODE_DEPENDENT.key?(c)
    stack.empty? or refuse("the leaf call #{c} is named mode-dependent and reaches #{stack.join(', ')} in leaves.rb")
    next
  end
  stack.empty? and refuse("the leaf call #{c} reaches nothing in #{opt[:leaves]}")
  until stack.empty?
    d = stack.pop
    next if reached[d]
    reached[d] = true
    stack.concat(leaves[d] & leaves.keys)
  end
end
unreached = leaves.keys - reached.keys
unreached.empty? or
  refuse("#{unreached.join(', ')} #{unreached.length == 1 ? 'is' : 'are'} defined in leaves.rb and no leaf call in " \
         "source-port.rb reaches #{unreached.length == 1 ? 'it' : 'them'}: the frame lane never checks it")

# THE ORIGINALS: the ledger rows that name a leaves.rb definition.
originals = []
named = {}
File.foreach(File.join(ROOT, "tools/doom/core-migrated.tsv")) do |l|
  next if l.start_with?("#")
  orig, into = l.split("\t")
  hit = into.to_s.split(",") & leaves.keys
  next if hit.empty?
  orig.start_with?("Renderer#") or refuse("#{orig} replaces #{hit.join(', ')} and is not a Renderer method this file can wrap")
  originals << orig
  hit.each { |d| named[d] = true }
end
unnamed = leaves.keys - named.keys
unnamed.empty? or refuse("#{unnamed.join(', ')} in leaves.rb is named by no row of tools/doom/core-migrated.tsv")

# WHAT EACH WRITES, through its callees too.
writes = Hash.new { |h, k| h[k] = [] }
File.foreach(state_use) do |l|
  next if l.start_with?("#", "class\t")
  f = l.chomp.split("\t")
  next unless f[0] == "Renderer"
  f[10].to_s.split(",").each { |d| writes[d] << f[1] }
end
edges = Hash.new { |h, k| h[k] = [] }
File.foreach(closure) do |l|
  next if l.start_with?("#")
  f = l.chomp.split("\t")
  edges[f[0]] << f[8] if f[1] == "call" && f[8].to_s.start_with?("Renderer#")
end
WRITTEN = originals.to_h do |o|
  seen = {}
  stack = [o]
  until stack.empty?
    d = stack.pop
    next if seen[d]
    seen[d] = true
    stack.concat(edges[d])
  end
  [o, seen.keys.flat_map { |d| writes[d] }.uniq.sort]
end

# HOW MUCH OF A WRITTEN FIELD ONE CALL CAN HAVE TOUCHED. `planes` is the
# visplane a call names: its result, and for check_plane the plane it was given
# and for clear_plane_top the plane it clears.
def planes(leaf, args, res)
  ([args.first] * (%i[check_plane clear_plane_top].include?(leaf) ? 1 : 0) + [res])
    .select { |p| p.is_a?(Integer) && p >= 0 }.uniq
end
row = ->(r, v, leaf, args, res) { planes(leaf, args, res).map { |p| r.instance_variable_get(v)[p] } }
scalar = ->(r, v, *) { r.instance_variable_get(v) }
segs = ->(r, v, *) { r.instance_variable_get(v)[0, r.instance_variable_get(:@newend) + 1] }
vis = ->(r, v, *) { r.instance_variable_get(v)[0, r.instance_variable_get(:@vis_n)] }
SLICES = {
  "@lastvisplane" => scalar, "@newend" => scalar, "@vis_n" => scalar, "@spritelights" => scalar,
  "@pl_height" => row, "@pl_picnum" => row, "@pl_lightlevel" => row, "@pl_minx" => row, "@pl_maxx" => row,
  "@pl_top" => lambda { |r, v, leaf, args, res|
    w = r.instance_variable_get(:@plw)
    planes(leaf, args, res).map { |p| r.instance_variable_get(v)[p * w, w] }
  },
  "@ss_first" => segs, "@ss_last" => segs,
  "@sector_validcount" => ->(r, v, *) { r.instance_variable_get(v).dup },
  **%w[@vs_mobjflags @vs_scale @vs_gx @vs_gy @vs_gz @vs_gzt @vs_texturemid @vs_x1 @vs_x2 @vs_startfrac
       @vs_xiscale @vs_patch @vs_cmap @vs_sorted @vs_taken].to_h { |v| [v, vis] }
}.freeze
all_written = WRITTEN.values.flatten.uniq
(all_written - SLICES.keys).then do |m|
  m.empty? or refuse("#{m.join(', ')} #{m.length == 1 ? 'is' : 'are'} written by a leaf and has no slice here")
end
(SLICES.keys - all_written).then do |m|
  m.empty? or refuse("#{m.join(', ')} #{m.length == 1 ? 'has' : 'have'} a slice here and no leaf writes it")
end
if opt[:check]
  puts "#{PROG}: #{leaves.length} definitions reached from #{leaf_calls.split.length} leaf calls, " \
       "#{originals.length} originals, #{all_written.length} written fields"
  exit 0
end

wad, demo, tics, mode = ARGV
LEAVES = originals.map { |o| o.delete_prefix("Renderer#").to_sym }.freeze
BREAK = opt[:break]&.split(":")&.then { |l, n| [l.to_sym, Integer(n)] }
BREAK.nil? || LEAVES.include?(BREAK[0]) or refuse("--break names #{BREAK[0]}, which is not a leaf here")
$digest = Hash.new { |h, k| h[k] = Digest::SHA256.new }
$calls = Hash.new(0)
require File.join(ROOT, "examples/doom/lib/doom/render")
Doom::Renderer.prepend(Module.new do
  LEAVES.each do |leaf|
    written = WRITTEN.fetch("Renderer##{leaf}")
    define_method(leaf) do |*args|
      res = super(*args)
      n = ($calls[leaf] += 1)
      @pl_top[0] += 1 if BREAK == [leaf, n]
      state = written.map { |v| SLICES.fetch(v).call(self, v, leaf, args, res) }
      $digest[leaf] << Marshal.dump([args, res, state])
      res
    end
  end
end)
Dir.mktmpdir("leaf-modes") do |out|
  ARGV.replace([wad, demo, tics, out, WHAT])
  $stdout = File.open(File::NULL, "w")
  load File.join(ROOT, "examples/doom/bin/sim_demo.rb")
  $stdout = STDOUT
end
LEAVES.sort.each { |l| puts "leaf #{l} calls #{$calls[l]} digest #{$calls[l].zero? ? '-' : $digest[l].hexdigest[0, 32]}" }
puts "#{PROG} #{demo} mode #{mode} tics #{tics} leaves #{LEAVES.length} written #{all_written.length}"
