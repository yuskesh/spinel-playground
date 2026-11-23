# frozen_string_literal: true
#
# tests/core-report/catalogue.rb -- the unknown-loop catalogue, from reports.
#
#   ruby catalogue.rb --out DIR [--map GROUP=MAP ...] GROUP.NAME.json ...
#
# Decision 0010 step 1 publishes the loops the rules could not bound, so that
# the strict rules of step 4 are designed from what the code actually contains.
# This reads build reports and writes, into DIR:
#
#   loops.tsv        every loop of every entry: its verdict, bound or reason
#   catalogue.tsv    the loops whose verdict is unknown, one row per entry
#   occurrences.tsv  the work-bound terms that are unknown although their loop
#                    passes (argument-not-expressible, enclosing-unknown)
#   summary.json     counts: per entry, per loop, per unique loop, per reason
#
# A report's file name starts with its group, and `--map GROUP=MAP` names that
# group's pack-core map, which turns a packed line back into the maintained
# unit and line it came from. A loop reached from several entries is counted
# once among the unique loops, keyed by id and digest.

require "json"
require "optparse"
require_relative "lib"

opt = { maps: {} }
OptionParser.new do |o|
  o.on("--out DIR") { |v| opt[:out] = v }
  o.on("--map GROUP=MAP") { |v| g, m = v.split("=", 2); opt[:maps][g] = m }
end.parse!
abort "catalogue.rb: --out is required" unless opt[:out]
abort "catalogue.rb: no reports given" if ARGV.empty?

def read_map(path)
  File.readlines(path, chomp: true).reject { |l| l.start_with?("#", "packed_start_line") }.map do |l|
    s, e, unit, = l.split("\t")
    [s.to_i, e.to_i, unit]
  end
end
maps = opt[:maps].transform_values { |p| read_map(p) }

def origin(maps, group, location)
  line = location[/:(\d+):\d+\z/, 1].to_i
  map = maps[group]
  return ["-", "-"] unless map
  hit = map.find { |s, e, _| line.between?(s, e) }
  hit ? [hit[2], (line - hit[0] + 1).to_s] : ["-", "-"]
end

# The leading token of an expressibility detail. For `A && B`, where the detail
# lists each conjunct as `conjunct N: reason (detail)`, the first conjunct's.
def token(reason, detail)
  return "-" unless %w[bound-not-expressible start-not-expressible].include?(reason) && detail
  detail = detail[/\Aconjunct 0: [a-z-]+ \((.*)/, 1] || detail
  detail[/\A([a-z][a-z-]*)/, 1] || "-"
end

def cell(value)
  value.nil? || value.to_s.empty? ? "-" : value.to_s.tr("\t\n", "  ")
end

loops_rows = []
catalogue_rows = []
occurrence_rows = []
unique = {}
entries = { "pass" => 0, "unknown" => 0 }
occ_counts = Hash.new(0)
term_total = 0
term_known = 0

ARGV.sort.each do |path|
  group = File.basename(path).split(".").first
  report = JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
  lb = report.dig("properties", "loop_bound")
  entry = report["entry"]
  entries[lb["verdict"]] += 1
  lb["loops"].each do |l|
    unit, unit_line = origin(maps, group, l["location"])
    bound = l.dig("evidence", 0, "value", "expression")
    tok = token(l["reason"], l["detail"])
    loops_rows << [entry, l["id"], l["verdict"], l["verdict"] == "pass" ? bound : l["reason"],
                   tok, unit, unit_line, l["location"], l["header"], l["digest"]]
    key = [l["id"], l["digest"]]
    unique[key] ||= { "verdict" => l["verdict"], "reason" => l["reason"], "token" => tok,
                      "unit" => unit, "entries" => [] }
    unique[key]["entries"] << entry
    next if l["verdict"] == "pass"
    catalogue_rows << [entry, l["id"], l["reason"], tok, unit, unit_line, l["location"],
                       l["header"], l["digest"], l["detail"]]
  end
  lb["work_bound"]["terms"].each do |t|
    term_total += 1
    term_known += 1 if t["iterations"]
    next unless %w[argument-not-expressible enclosing-unknown].include?(t["reason"])
    occ_counts[t["reason"]] += 1
    occurrence_rows << [entry, t["loop"], t["reason"], t["context"].join(" > "), t["detail"]]
  end
end

def write_tsv(path, header, rows)
  File.open(path, "w") do |f|
    f.puts header.join("\t")
    rows.each { |r| f.puts r.map { |v| cell(v) }.join("\t") }
  end
end

write_tsv(File.join(opt[:out], "loops.tsv"),
          %w[entry loop verdict bound_or_reason detail_token unit unit_line location header digest], loops_rows)
write_tsv(File.join(opt[:out], "catalogue.tsv"),
          %w[entry loop reason detail_token unit unit_line location header digest detail], catalogue_rows)
write_tsv(File.join(opt[:out], "occurrences.tsv"),
          %w[entry loop reason context detail], occurrence_rows)

by_reason = Hash.new(0)
by_token = Hash.new(0)
unique.each_value do |u|
  next if u["verdict"] == "pass"
  by_reason[u["reason"]] += 1
  by_token["#{u['reason']} #{u['token']}"] += 1 unless u["token"] == "-"
end
summary = {
  "reports" => ARGV.length,
  "entries" => entries,
  "loop_rows" => { "total" => loops_rows.length, "unknown" => catalogue_rows.length },
  "unique_loops" => {
    "total" => unique.length,
    "pass" => unique.count { |_, u| u["verdict"] == "pass" },
    "unknown" => unique.count { |_, u| u["verdict"] != "pass" },
    "unknown_by_reason" => by_reason.sort.to_h,
    "unknown_by_detail" => by_token.sort.to_h
  },
  "terms" => {
    "total" => term_total,
    "known" => term_known,
    "unknown_with_passing_loop" => occ_counts.sort.to_h
  }
}
# The same canonical emitter the goldens use, so a summary from one host can
# be compared with another's byte for byte.
File.binwrite(File.join(opt[:out], "summary.json"), CoreReport::Json.dump(summary))
puts "catalogue: #{ARGV.length} report(s), #{unique.length} unique loop(s), " \
     "#{summary['unique_loops']['unknown']} unknown"
