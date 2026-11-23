# frozen_string_literal: true
#
# tests/doom-core/copy-check.rb — the boundary copy carries exactly what it must.
#
#   ruby tests/doom-core/copy-check.rb --state-use AUDIT/state-use.tsv [--copy FILE]
#
# A buffer MUST be in the copy when step writes it, render reads it, and a PORTED
# CORE definition is among the ones that read it. It MUST NOT be when no ported
# definition reads it -- a copy nothing reads cannot be left out in a way that
# turns anything red, so it would be a copy that could not fail.
#
# "A PORTED DEFINITION READS IT" HAS TWO SOURCES, and each misses what the other
# sees. Measured on the four the copy first carried:
#
#   state-use.tsv's readers, joined with core-migrated.tsv, catches a read by a
#   MIGRATED definition -- StatusBar#draw reading the three status_bar_*, which
#   the port receives as arguments and fields.tsv therefore never names.
#
#   fields.tsv catches a read through a PORTED ENTRY'S PARAMETER -- the plane
#   entry reading textures_flattranslation. The audit's reader for that is
#   Textures#flatdata, an accessor the port ABSORBED into dc_draw_plane and the
#   ledger does not record, so the first source cannot see it.
#
# The union is the requirement. If absorption is ever recorded in the ledger, the
# second source becomes derivable from the first and can go.
require "optparse"
require "set"

ROOT = File.expand_path("../..", __dir__)
opt = { copy: File.join(ROOT, "tests/doom-core/fixtures/source/copy.tsv") }
OptionParser.new do |o|
  o.on("--state-use FILE") { |v| opt[:state_use] = v }
  o.on("--copy FILE") { |v| opt[:copy] = v }
  # print the coupled buffers no ported definition reads, one per line, and stop:
  # the failing input for "a buffer nothing ported reads" is chosen from these
  # rather than named, since a name goes stale when its first reader is ported
  o.on("--list-unread") { opt[:list_unread] = true }
end.parse!
opt[:state_use] or abort("copy-check.rb: --state-use names the audit's state-use.tsv")
data = ->(path) { File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? } }
snake = ->(c) { c.gsub(/([a-z])([A-Z])/, "\\1_\\2").downcase }

access = Hash.new { |h, k| h[k] = {} }
data.(File.join(ROOT, "examples/doom/core/access.tsv")).each do |l|
  entry, field, use = l.chomp.split("\t")
  access[field][:step] = true if entry == "doom_core_step" && %w[out inout].include?(use)
  access[field][:render] = true if entry == "doom_core_render" && %w[in inout].include?(use)
end
coupled = access.select { |_, v| v[:step] && v[:render] }.keys.to_set

migrated = data.(File.join(ROOT, "tools/doom/core-migrated.tsv")).map { |l| l.split("\t")[0] }.to_set
readers = {}
data.(opt[:state_use]).each do |l|
  next if l.start_with?("class\t")
  f = l.chomp.split("\t")
  readers["#{snake.(f[0])}_#{f[1].delete_prefix('@')}"] = f[11].to_s.split(",").map(&:strip)
end
unmapped = coupled.reject { |c| readers.key?(c) }
unmapped.empty? or abort("copy-check.rb: no state-use row for #{unmapped.sort.join(' ')}; the name mapping has broken")

by_reader = coupled.select { |c| readers[c].any? { |d| migrated.include?(d) } }.to_set
by_param = data.(File.join(ROOT, "tests/doom-core/fixtures/source/fields.tsv")).map { |l| l.split("\t")[3] }.to_set & coupled
required = by_reader | by_param
carried = data.(opt[:copy]).map { |l| l.split("\t").first.strip }.to_set
if opt[:list_unread]
  puts (coupled - required).sort
  exit 0
end

missing = required - carried
extra = carried - required
missing.each { |b| puts "  FAIL #{b} is read by a ported definition and is not in the copy" }
extra.each { |b| puts "  FAIL #{b} is in the copy and no ported definition reads it" }
puts "copy-check: #{coupled.size} coupled, #{required.size} required, #{carried.size} carried, " \
     "#{missing.size} missing, #{extra.size} extra"
exit(missing.empty? && extra.empty? ? 0 : 1)
