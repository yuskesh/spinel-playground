# frozen_string_literal: true
#
# tools/core/subset-coverage.rb -- every entry of the freestanding subset
# table tied to the evidence for its refusal (decision 0026, step 2).
#
#   ruby tools/core/subset-coverage.rb [--refusals FILE] [--inherited FILE] [--map FILE] [--root DIR]
#   ruby tools/core/subset-coverage.rb --expect node|call ENTRY [--refusals FILE] [--inherited FILE]
#
# The table is in two files (decision 0026 step 5): the owned table,
# tools/mlir/native/lib/Core/SubsetRefusals.cpp (subsetRefusalNodes and
# subsetRefusalCalls), and the inherited list,
# tools/mlir/native/lib/Frontend/Scalar/SubsetTables.cpp (fsInheritedNodes):
# key and reason text. The map is
# tests/subset/coverage.tsv, one row per entry:
#
#   table     node or call
#   entry     the table key
#   evidence  `fixture PATH`: a fixture, relative to --root, whose first line
#             is `# subset-entry: TABLE ENTRY`; tests/subset/reasons.sh
#             requires spinel-fs-emit to refuse it with this entry's reason
#             text. Or `unverified-inherited`: no input reaches the entry
#             unmasked; the entry stays in force, named, not removed
#   note      for unverified-inherited, why (required); otherwise optional
#
# Without --expect it checks the map against the table and fails, one line
# per finding, naming its kind:
#
#   no row             a table entry the map has no row for
#   unknown entry      a row naming no table entry
#   duplicate row      two rows for one entry
#   bad evidence       evidence neither `fixture PATH` nor `unverified-inherited`
#   missing test       a fixture path that is not a file
#   fixture mismatch   a fixture whose first line names another entry
#   no reason          an unverified-inherited row with an empty note
#   wrong side         a fixture row whose entry is not in SubsetRefusals.cpp,
#                      or an unverified-inherited row whose entry is not in
#                      SubsetTables.cpp: the map decides which file holds a key
#   in both files      an entry both files list
#
# --expect prints the text spinel-fs-emit gives for that entry when it refuses
# a method `f`: `f: KIND is not in the freestanding subset -- REASON.` for a
# node, `f: REASON` for a call. Exit 0 when nothing failed, 1 when something
# did, 2 on a usage error or a table it cannot read.
require "optparse"

root = File.expand_path("../..", __dir__)
opt = {}
OptionParser.new do |o|
  o.on("--refusals FILE") { |v| opt[:refusals] = v }
  o.on("--inherited FILE") { |v| opt[:inherited] = v }
  o.on("--map FILE") { |v| opt[:map] = v }
  o.on("--root DIR") { |v| root = v }
  o.on("--expect") { opt[:expect] = true }
end.parse!
refusals_path = opt[:refusals] || File.join(root, "tools/mlir/native/lib/Core/SubsetRefusals.cpp")
inherited_path = opt[:inherited] || File.join(root, "tools/mlir/native/lib/Frontend/Scalar/SubsetTables.cpp")
map_path = opt[:map] || File.join(root, "tests/subset/coverage.tsv")
usage = ->(m) { warn "subset-coverage: #{m}"; exit 2 }

# A map's entries: `{"KEY",` then, in subsetRefusalNodes, `{RULE,`; then one
# or more adjacent C string literals, then `}` (`}}` after a rule). The
# reason text is their concatenation. fns: table kind => function name.
def read_table(path, fns)
  src = File.read(path)
  out = {}
  fns.each do |kind, fn|
    body = src[/#{fn}\(\)\s*\{.*?static const std::map<std::string, \w+(?:::\w+)?> t = \{(.*?)\n  \};/m, 1] or
      return nil
    out[kind] = {}
    body.scan(/\{\s*"((?:[^"\\]|\\.)*)",\s*(?:\{\s*\w+,)?((?:\s*"(?:[^"\\]|\\.)*")+)\s*\}/m) do |key, lits|
      out[kind][key] = lits.scan(/"((?:[^"\\]|\\.)*)"/).flatten.join.gsub(/\\(.)/, '\1')
    end
  end
  out
end

owned = File.file?(refusals_path) &&
        read_table(refusals_path, "node" => "subsetRefusalNodes", "call" => "subsetRefusalCalls") or
  usage.("cannot read the two maps of #{refusals_path}")
inherited = File.file?(inherited_path) && read_table(inherited_path, "node" => "fsInheritedNodes") or
  usage.("cannot read the map of #{inherited_path}")
inherited["call"] = {}
# The two files together: what the walk refuses, owned table first.
table = %w[node call].to_h { |k| [k, inherited[k].merge(owned[k])] }

if opt[:expect]
  kind, entry = ARGV
  reason = table.dig(kind.to_s, entry.to_s) or usage.("--expect: no #{kind} entry #{entry.inspect}")
  puts(kind == "node" ? "f: #{entry} is not in the freestanding subset -- #{reason}." : "f: #{reason}")
  exit 0
end

File.file?(map_path) or usage.("no map at #{map_path}")
failed = []
fail_ = ->(k, m) { failed << "#{k}: #{m}" }
rows = Hash.new { |h, k| h[k] = [] }
counts = Hash.new(0)
File.readlines(map_path, chomp: true).each_with_index do |l, i|
  next if l.empty? || l.start_with?("#")
  at = "#{File.basename(map_path)}:#{i + 1}"
  kind, entry, evidence, note = l.split("\t")
  rows[[kind, entry]] << at
  unless table.dig(kind.to_s, entry.to_s)
    fail_.("unknown entry", "#{at}: #{kind} #{entry}")
    next
  end
  case evidence.to_s
  when /\Afixture (\S+)\z/
    path = Regexp.last_match(1)
    counts["fixture"] += 1
    fail_.("wrong side", "#{at}: #{kind} #{entry} has a fixture, so it belongs in #{File.basename(refusals_path)}") unless owned.dig(kind.to_s, entry.to_s)
    full = File.join(root, path)
    if !File.file?(full)
      fail_.("missing test", "#{at}: #{kind} #{entry}: no file #{path}")
    elsif (first = File.open(full, &:gets).to_s.chomp) != "# subset-entry: #{kind} #{entry}"
      fail_.("fixture mismatch", "#{at}: #{kind} #{entry}: #{path} begins #{first.inspect}")
    end
  when "unverified-inherited"
    counts["unverified-inherited"] += 1
    fail_.("wrong side", "#{at}: #{kind} #{entry} is unverified-inherited, so it belongs in #{File.basename(inherited_path)}") unless inherited.dig(kind.to_s, entry.to_s)
    fail_.("no reason", "#{at}: #{kind} #{entry}") if note.to_s.strip.empty?
  else
    fail_.("bad evidence", "#{at}: #{kind} #{entry}: #{evidence.inspect}")
  end
end
rows.each { |(k, e), ats| fail_.("duplicate row", "#{k} #{e}: #{ats.join(', ')}") if ats.size > 1 }
owned.each do |kind, entries|
  entries.each_key { |e| fail_.("in both files", "#{kind} #{e}") if inherited[kind].key?(e) }
end
table.each do |kind, entries|
  entries.each_key { |e| fail_.("no row", "#{kind} #{e}") unless rows.key?([kind, e]) }
end

n = table.values.sum(&:size)
puts "subset-coverage: #{n} table entries (#{table['node'].size} node, #{table['call'].size} call); " \
     "rows: #{counts['fixture']} fixture, #{counts['unverified-inherited']} unverified-inherited"
failed.each { |m| puts "FAIL #{m}" }
puts "subset-coverage: #{failed.empty? ? 'ok' : "#{failed.size} failure(s)"}"
exit(failed.empty? ? 0 : 1)
