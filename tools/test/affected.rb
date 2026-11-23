# frozen_string_literal: true
#
# tools/test/affected.rb — the tests a change reaches, and why.
#
#   ruby tools/test/affected.rb --base REV [--closure FILE] [--root DIR]
#   ruby tools/test/affected.rb --scope PATH... [--root DIR]
#
# --scope lists the tracked files under each PATH that no row of the table
# matches, and exits 1 if there is one: the table is held to cover a tree
# before a change there needs it.
#
# The change is everything between REV and the working tree: `git diff REV`
# (committed, staged and unstaged) and the untracked files git does not
# ignore. Each changed file is matched against tools/test/affected.tsv, whose
# rows name tests of tools/test/tests.tsv; the first row that matches a file
# applies. The answer, on stdout:
#
#   run        the commands to run, each with the reasons that selected it
#              (which file, and for CORE source which definition and entry);
#   long       the same, for tests that take hours;
#   board      the board check;
#   excluded   tests the change reaches and which are not run: the CRuby and
#              recording comparisons tests.tsv marks `excluded`, the entries'
#              own comparisons for a CORE change, and the oracle sections
#              tests/ORACLES.tsv gates inside each selected test;
#   unmapped   changed files no row of affected.tsv matches.
#
# Under a selected test, `known failure` lines repeat tools/test/known.tsv: a
# failure it already had without the change, with the revision that showed it.
#
# Exit 1 when a file is unmapped: a file the table does not know is never
# read as needing no test. Exit 2 when it cannot decide (a bad revision, a
# table naming an unknown test, CORE source changed and no closure to read).
#
# CORE SOURCE (examples/doom/core/src/*.rb, `@core-src` in the table). The
# changed lines (git diff -U0, both sides) are placed in the definitions they
# fall in, using Prism only for each top-level `def`'s line range (all of
# that directory's definitions are top level). A definition reaches an entry
# through two committed facts and one measured one:
#
#   * tools/doom/core-migrated.tsv: the original (Full) definitions each CORE
#     definition replaces;
#   * the audit's closure (tools/doom/audit-core.rb's closure.tsv, --closure,
#     or run here with SPINEL_TYPEDUMP as the reader): the domain -- input,
#     step or render -- each original is reached from;
#   * examples/doom/core/entries/units.tsv: which units are packed into the
#     entries at all.
#
# A definition that reaches an entry selects the board lane, the packer's and
# the entries' suites and tests/doom-core/host-frames.sh (the built entries on
# this host, DEMO1's first 500 tics against the recording), and the long
# lanes below.
#
# A changed file tests/doom/manifest.tsv pins by digest also selects
# tools/doom/verify-sources.sh, whichever row matched it, and so does a file
# added to or changed in a directory holding pinned files, or one under it
# (README.md and *.sh aside, as verify-sources.sh leaves them out): that
# script requires every file there to be named by the manifest.
#
# A changed file tools/dist/manifest.json rewrites (pinned by sha256), or the
# manifest itself, selects the real export (dist-export).
#
# EVERY changed file also selects tests/imports/run.sh, whichever row matched
# it (or none): a new, moved or edited file can fall outside docs/imports.tsv
# or change what an SPDX line says.
#
# A changed line outside every definition, a definition with no row in
# core-migrated.tsv, or an original the closure does not show, reaches every
# entry: when the facts do not narrow it, the answer is all three, and says
# so.
require "fileutils"
require "json"
require "open3"
require "optparse"
require "prism"
require "set"
require "tmpdir"

opt = { root: File.expand_path("../..", __dir__) }
OptionParser.new do |o|
  o.on("--base REV") { |v| opt[:base] = v }
  o.on("--closure FILE") { |v| opt[:closure] = v }
  o.on("--root DIR") { |v| opt[:root] = File.expand_path(v) }
  o.on("--scope") { opt[:scope] = true }
end.parse!
die = ->(msg) { warn "affected: #{msg}"; exit 2 }
opt[:base] || opt[:scope] or die.("--base REV or --scope PATH... is required")
ROOT = opt[:root]
git = lambda do |*args|
  out, err, st = Open3.capture3("git", "-C", ROOT, *args)
  die.("git #{args.join(' ')}: #{err.strip}") unless st.success?
  out
end
git.("rev-parse", "--verify", "--quiet", "#{opt[:base]}^{commit}") if opt[:base]
rows = ->(path) { File.readlines(File.join(ROOT, path), chomp: true).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t") } }

Test = Struct.new(:id, :kind, :command, :note)
tests = rows.("tools/test/tests.tsv").to_h { |id, kind, cmd, note| [id, Test.new(id, kind, cmd, note)] }
# A trailing `/**` means everything under the directory, at any depth. Under
# FNM_PATHNAME a bare `**` matches one level only (docs/** missed
# docs/core/x.md), so it is read as `/**/*`, which matches every depth.
table = rows.("tools/test/affected.tsv").map { |g, ids, why| [g.sub(%r{/\*\*\z}, "/**/*"), ids.split(","), why, g] }
table.each do |g, ids, _|
  ids.each { |i| die.("affected.tsv: #{g} names #{i}, which tests.tsv does not list") unless i == "@core-src" || tests.key?(i) }
end
oracles = rows.("tests/ORACLES.tsv").reject { |_, _, cls, _| %w[exempt program].include?(cls) }
known = rows.("tools/test/known.tsv").group_by(&:first)
known.each_key { |id| die.("known.tsv names #{id}, which tests.tsv does not list") unless tests.key?(id) }

match = ->(f) { table.find { |g, _, _| File.fnmatch(g, f, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
if opt[:scope]
  die.("--scope needs at least one PATH") if ARGV.empty?
  tracked = git.("ls-files", "--", *ARGV).lines(chomp: true)
  missing = tracked.reject { |f| match.(f) }
  puts "affected: #{tracked.size} tracked file(s) under #{ARGV.join(' ')}, #{missing.size} no row matches"
  missing.each { |f| puts "  #{f}" }
  exit(missing.empty? ? 0 : 1)
end
changed = git.("diff", "--name-only", opt[:base]).lines(chomp: true)
untracked = git.("ls-files", "--others", "--exclude-standard").lines(chomp: true)
files = (changed + untracked).uniq.sort

selected = Hash.new { |h, k| h[k] = [] } # test id => reasons
excluded = Hash.new { |h, k| h[k] = [] } # name => reasons
unmapped = []

# --- CORE source: the changed definitions, and the entries they reach
ENTRIES = %w[input step render].freeze
PARTS = { "input" => ["doom-verify: input-diff.rb, the input entry against the original"],
          "step" => ["doom-verify: step-diff.rb over every tic and the scenarios, the step entry against the original"],
          "render" => ["doom-verify: render-diff.rb, the render entry against the original",
                       "doom-verify: the route's screens against the original's recordings"] }.freeze
closure = nil
load_closure = lambda do
  return closure if closure
  path = opt[:closure]
  unless path
    reader = ENV["SPINEL_TYPEDUMP"] or die.("CORE source changed: give --closure (the audit's closure.tsv) or SPINEL_TYPEDUMP to run the audit")
    dir = Dir.mktmpdir("affected-closure")
    at_exit { FileUtils.rm_rf(dir) }
    _, err, st = Open3.capture3(RbConfig.ruby, File.join(ROOT, "tools/doom/audit-core.rb"), "--reader", reader,
                                "--tables", File.join(ROOT, "tools/doom"), "--output", dir)
    die.("the audit did not run: #{err.lines.last}") unless st.success? || File.file?(File.join(dir, "closure.tsv"))
    path = File.join(dir, "closure.tsv")
  end
  domains = Hash.new { |h, k| h[k] = Set.new }
  File.foreach(path) do |l|
    next if l.start_with?("#", "from\t")
    f = l.chomp.split("\t")
    domains[f[0]] << f[7] if f.size >= 8 && ENTRIES.include?(f[7])
  end
  closure = domains
end
migrated = Hash.new { |h, k| h[k] = [] } # CORE def => originals
rows.("tools/doom/core-migrated.tsv").each { |orig, cores, _| cores.split(",").each { |c| migrated[c] << orig } }
units = rows.("examples/doom/core/entries/units.tsv").map(&:first)
defs_in = lambda do |src, label|
  res = Prism.parse(src)
  die.("#{label}: Prism cannot parse it (#{res.errors.first.message})") unless res.errors.empty?
  res.value.statements.body.grep(Prism::DefNode).map { |d| [d.name.to_s, d.location.start_line, d.location.end_line] }
end
core_src = lambda do |path|
  unit = File.basename(path)
  unless units.include?(unit)
    return [[], ["#{path}: #{unit} is not packed into the entries (units.tsv excludes it)"]]
  end
  new_src = File.file?(File.join(ROOT, path)) ? File.read(File.join(ROOT, path)) : ""
  old_src, = Open3.capture2("git", "-C", ROOT, "show", "#{opt[:base]}:#{path}")
  new_defs = defs_in.(new_src, path)
  old_defs = old_src.empty? ? [] : defs_in.(old_src, "#{opt[:base]}:#{path}")
  hit = Set.new
  outside = false
  place = lambda do |defs, line|
    d = defs.find { |_, a, b| line.between?(a, b) }
    d ? hit << d[0] : outside = true
  end
  if untracked.include?(path)
    new_defs.each { |d| hit << d[0] }
  else
    git.("diff", "-U0", opt[:base], "--", path).scan(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) do |a, b, c, d|
      (a.to_i...(a.to_i + (b || "1").to_i)).each { |l| place.(old_defs, l) }
      (c.to_i...(c.to_i + (d || "1").to_i)).each { |l| place.(new_defs, l) }
    end
  end
  reach = Set.new
  why = []
  hit.sort.each do |name|
    origs = migrated[name]
    doms = origs.flat_map { |o| load_closure.()[o].to_a }.uniq
    if doms.empty?
      reach.merge(ENTRIES)
      why << "#{path}: def #{name}: #{origs.empty? ? 'no row in core-migrated.tsv' : "#{origs.join(', ')} not in the audit's closure"}, so every entry"
    else
      reach.merge(doms)
      why << "#{path}: def #{name} replaces #{origs.join(', ')}, reached from #{doms.sort.join(', ')}"
    end
  end
  if outside
    reach.merge(ENTRIES)
    why << "#{path}: lines outside every definition, so every entry"
  end
  [reach.to_a.sort, why]
end

files.each do |f|
  hit = match.(f)
  if hit.nil?
    unmapped << f
    next
  end
  [hit].each do |_, ids, why, g|
    ids.each do |id|
      if id == "@core-src"
        reach, whys = core_src.(f)
        whys.each do |w|
          %w[doom-board doom-source-pack doom-entries doom-host-frames].each { |t| selected[t] << w }
        end
        selected["doom-capacity"].concat(whys) if reach.include?("step")
        selected["doom-loop-reports"].concat(whys) unless reach.empty?
        reach.each { |e| PARTS[e].each { |p| excluded[p] << "#{f}: the #{e} entry" } }
      elsif tests[id].kind == "excluded"
        excluded["#{id}: #{tests[id].note}"] << "#{f} (#{g}: #{why})"
      else
        selected[id] << "#{f} (#{g}: #{why})"
      end
    end
  end
end
# A file tests/doom/manifest.tsv pins by digest (its fifth column) must agree
# with it, whatever row matched: tools/doom/verify-sources.sh checks that.
pinned = rows.("tests/doom/manifest.tsv").map { |r| r[4] }.compact.to_set
files.each { |f| selected["doom-sources"] << "#{f}: pinned in tests/doom/manifest.tsv" if pinned.include?(f) }
# So must a file added to, or changed in, a directory holding pinned files or
# one under it: verify-sources.sh requires every file under the imported
# directories, README.md and *.sh aside, to be named by the manifest, so a
# file new there fails it until the manifest lists it.
pinned_dirs = pinned.map { |p| File.dirname(p) }.to_set
files.each do |f|
  next if pinned.include?(f) || File.basename(f) == "README.md" || f.end_with?(".sh")
  d = File.dirname(f)
  next unless pinned_dirs.any? { |p| d == p || d.start_with?("#{p}/") }
  selected["doom-sources"] << "#{f}: in #{d}, where tests/doom/manifest.tsv pins files"
end
# A file tools/dist/manifest.json rewrites is pinned there by sha256, before
# and after its edits, and the real export stops on a stale pin (98b873e
# changed two such files and did not re-pin them). So does a change to the
# manifest itself. The set is read from the manifest, whatever row matched.
dist_manifest = "tools/dist/manifest.json"
if tests.key?("dist-export") && File.file?(File.join(ROOT, dist_manifest))
  rewritten = JSON.parse(File.read(File.join(ROOT, dist_manifest)))["rewrites"].map { |r| r["path"] }.to_set
  files.each do |f|
    selected["dist-export"] << "#{f}: the export's manifest" if f == dist_manifest
    selected["dist-export"] << "#{f}: #{dist_manifest} pins it (a rewrite's source and output sha256)" if rewritten.include?(f)
  end
end
# Every changed file can break docs/imports.tsv: a new or moved file no row
# covers, or an SPDX line its row does not name.
files.each { |f| selected["imports"] << "#{f}: every tracked file is under one row of docs/imports.tsv" } if tests.key?("imports")
# So can it break tests/oracle/check.sh, whose patterns read words on any line
# of any file: a message that comes to say "oracle" or "CRuby" makes its file
# look like an oracle with no row (D2's commit 6). The check takes seconds.
files.each { |f| selected["oracle-check"] << "#{f}: tests/oracle/check.sh reads every file for the oracle patterns" } if tests.key?("oracle-check")
# a selected test's own gated sections
selected.each_key do |id|
  script = tests[id].command[%r{(tests/\S+\.sh)}, 1] or next
  oracles.select { |p, _, _, _| p == script }.each do |_, sec, cls, what|
    excluded["#{script} #{sec} (ORACLES.tsv, #{cls}): #{what}"] << "a section of #{id}, gated without ALLOW_ORACLE"
  end
end

out = ->(title, list) { puts "#{title}:"; list.empty? ? puts("  (none)") : list.each { |l| puts l } }
group = lambda do |kind|
  selected.select { |id, _| tests[id].kind == kind }.sort.map do |id, why|
    "  #{tests[id].command}\n" + why.uniq.map { |w| "      <- #{w}" }.join("\n") +
      (known[id] || []).map { |_, check, since, reason| "\n      known failure (since #{since}): #{check} -- #{reason}" }.join
  end
end
puts "affected: #{files.size} changed file(s) since #{opt[:base]}"
out.("run", group.("run"))
out.("long", group.("long"))
out.("board", group.("board"))
out.("excluded", excluded.sort.map { |n, why| "  #{n}\n" + why.uniq.map { |w| "      <- #{w}" }.join("\n") })
out.("unmapped", unmapped.map { |f| "  #{f}" })
if unmapped.any?
  warn "affected: #{unmapped.size} changed file(s) no row of tools/test/affected.tsv matches; add rows before trusting this list"
  exit 1
end
