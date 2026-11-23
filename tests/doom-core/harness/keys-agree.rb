# tests/doom-core/harness/keys-agree.rb — the record's keys against the report's.
#
#   ruby tests/doom-core/harness/keys-agree.rb [--keys FILE] RECORD.json REPORT.txt [...]
#
# source-port.rb builds its result record's keys BESIDE the report lines, from
# the values those lines print. report_keys.rb reads the printed text back. The
# two are independent renderings of one run, so requiring them to agree is what
# holds either from drifting: a key that stops following its line, a line whose
# format changes without its key, a key spelled one way in one place.
#
# It checks three things per case and names what failed:
#
#   1. every line of the report is claimed by a rule (nothing printed is
#      unaccounted for);
#   2. every key the text yields is in the record, with the same value;
#   3. every record key the text cannot yield is one of the RECORD_ONLY names
#      below, under the condition that makes it legitimate;
#   4. no key of the record is one the key inventory marks RETIRED.
#
# Exit status is 0 when every pair agrees, 1 otherwise.
#
# WHY THE RETIREMENT RULE'S SECOND HALF IS HERE. A retired key is one only the
# frozen pins can produce: tests/doom-core/harness/keys.rb names them, with the
# revision that retired each and why, and the rule has two halves. The first --
# a retired key is STILL ACCEPTED when a frozen pin is parsed, because the pin is
# the record of what the old check asserted -- belongs to keys.rb, which is where
# a pin's key becomes an inventory row. The second -- A CURRENT RECORD THAT
# CARRIES A RETIRED KEY IS AN ERROR -- needs a current record, and keys.rb never
# sees one: it reads pins, a case matrix and a control table, and would have to
# be handed a run to enforce it. expect.rb never sees one either. THIS is the
# program a current record is handed to, so this is where the second half can be
# enforced at all, and putting it in both would mean a generator refusing the
# very pins it exists to read.
#
# It reads the names out of the GENERATED INVENTORY rather than restating them,
# so `retired` is declared once, in keys.rb, and a regenerated keys.tsv is what
# this follows. A missing inventory is an error and not a skip: running with half
# the rule silently disabled is the failure this check exists to prevent.

require "json"
require_relative "report_keys"

KEYS = File.expand_path("../expect/keys.tsv", __dir__)
KEY_COLUMNS = %w[#route key type dynamic family stage1 reason].freeze
RETIRED_STAGE1 = "retired".freeze

# key -> the inventory's reason, for every row the inventory marks retired. The
# mark is a property of the key, not of one route -- a key no current run can
# carry is carried by no route's run -- so the routes collapse into one list.
def read_retired(path)
  File.exist?(path) or
    abort("keys-agree.rb: no key inventory at #{path}; regenerate it with keys.rb, or name one with --keys")
  retired = {}
  header = nil
  File.readlines(path, chomp: true).each do |line|
    next if line.empty?
    if line.start_with?("#")
      fields = line.split("\t")
      header = fields if fields.first == KEY_COLUMNS.first
      next
    end
    fields = line.split("\t", -1)
    fields.length == KEY_COLUMNS.length or
      abort("keys-agree.rb: #{path} has a row of #{fields.length} fields, not #{KEY_COLUMNS.length}")
    row = KEY_COLUMNS.zip(fields).to_h
    retired[row["key"]] ||= row["reason"] if row["stage1"] == RETIRED_STAGE1
  end
  header == KEY_COLUMNS or
    abort("keys-agree.rb: the key inventory #{path} has the columns #{header.inspect}, not #{KEY_COLUMNS.inspect}")
  retired
end

# Keys the record holds that no printed line carries, named one at a time with
# the condition that makes each legitimate. Anything else the record holds and
# the report does not is a defect, so this list is the whole licence.
#
#   first_at.<kind>.frame / .tic  taken where the fault was raised; the report
#                                 prints the fault's text, not where it was hit.
#   adapter.session_failed = "-"  the line is printed only by a session that
#                                 failed, and the record answers on both paths
#                                 so that a missing key is never read as "fine".
#   rc                            the program prints no exit status; tick.sh
#                                 appends one to the text it compares, so a
#                                 report may or may not carry it, and where it
#                                 does the two are compared like any other key.
RECORD_ONLY = [
  [/\Afirst_at\.[^.]+\.(frame|tic)\z/, ->(_v) { true }],
  [/\Aadapter\.session_failed\z/, ->(v) { v == "-" }],
  [/\Arc\z/, ->(_v) { true }]
].freeze

def record_only?(key, value)
  RECORD_ONLY.any? { |pattern, ok| pattern.match?(key) && ok.call(value) }
end

def check(record_path, report_path, retired, keys_path)
  doc = JSON.parse(File.read(record_path))
  have = doc["keys"]
  # tick.sh appends the exit status as a last line; a record carries it as a
  # field. Compare them under the one name the expectations use.
  have = have.merge("rc" => doc["rc"]) if doc.key?("rc")
  want, unparsed = ReportKeys.parse(File.read(report_path))

  problems = []
  unparsed.each { |l| problems << "unparsed report line: #{l}" }
  want.each do |k, v|
    if !have.key?(k)
      problems << "key #{k} is in the report and not in the record"
    elsif have[k] != v
      problems << "key #{k}: record #{have[k].inspect}, report #{v.inspect}"
    end
  end
  (have.keys - want.keys).each do |k|
    problems << "key #{k} is in the record and in no report line" unless record_only?(k, have[k])
  end
  # The retirement rule's second half. A run that carries a retired key has
  # brought a renamed entry back under its old name, which is precisely what the
  # mark exists to catch, so it is a problem of this record and not a note.
  (have.keys & retired.keys).sort.each do |k|
    problems << "key #{k} is RETIRED in #{keys_path} and this record carries it: #{retired[k]}"
  end
  [want.size, problems]
end

args = ARGV.dup
keys_path = KEYS
while args.first == "--keys"
  args.shift
  keys_path = args.shift or abort("keys-agree.rb: --keys needs a value")
end
paths = args.each_slice(2).to_a
paths.empty? and abort("usage: keys-agree.rb [--keys FILE] RECORD.json REPORT.txt [RECORD.json REPORT.txt ...]")
retired = read_retired(keys_path)
failed = 0
paths.each do |record_path, report_path|
  report_path or abort("keys-agree.rb: #{record_path} has no report beside it")
  compared, problems = check(record_path, report_path, retired, keys_path)
  name = File.basename(record_path, ".json")
  if problems.empty?
    puts "keys-agree: #{name} #{compared} keys agree"
  else
    failed += 1
    problems.each { |p| puts "keys-agree: #{name} #{p}" }
  end
end
puts "keys-agree: #{paths.length} compared, #{failed} disagree"
exit(failed.zero? ? 0 : 1)
