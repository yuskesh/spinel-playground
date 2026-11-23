# tests/doom-core/harness/fills.rb — the rows that fill the frame lane's TBDs.
#
#   ruby tests/doom-core/harness/fills.rb --expect UNFILLED.tsv --records DIR
#        [--records DIR ...] [--cases FILE] [--out FILE]
#
# harness/expect.rb writes `TBD` for every value no frozen pin holds and no case
# declaration fixes -- the coverage counts of the two 200-frame nominals, the
# adapter's id counts, the wrong-slot case's first failure. Those values exist
# only in a run's result records. This reads the records and writes the rows
# that fill them, so that `tests/doom-core/expect/frame-fills.tsv` is PRODUCED
# from a run rather than typed from a log, and so that every filled value in the
# generated expectation names the record it came from.
#
# THE THREE STEPS, in order. The middle one needs the expectation as it is
# generated WITHOUT `--fills`, because that is the file that still holds the
# `TBD` rows; the third writes the tracked one.
#
#   ruby tests/doom-core/harness/expect.rb --pins PINS.tsv --out UNFILLED.tsv
#   ruby tests/doom-core/harness/fills.rb --expect UNFILLED.tsv --records RUNDIR \
#        --out tests/doom-core/expect/frame-fills.tsv
#   ruby tests/doom-core/harness/expect.rb --pins PINS.tsv \
#        --fills tests/doom-core/expect/frame-fills.tsv \
#        --out tests/doom-core/expect/frame.tsv
#
# It emits EXACTLY the rows the TBDs need, and no others: a row for a key that
# is not TBD would be a value asserted here rather than derived by the
# generator, and expect.rb refuses one.
#
# THE RECORD MUST BE THE CASE'S OWN RUN. `--records DIR` names a run directory,
# and the record of a case is `DIR/records/<case id>.json`, which is where
# run.rb wrote it. Before a value is taken out of one, the record's route, mode,
# control and requested tic count are checked against the matrix row -- the same
# identification run.rb makes -- so a record left behind by a different case or
# a different frame count cannot supply a number. Several run directories may be
# given; one case's record must appear in exactly one of them, because two
# copies could disagree and nothing here could say which run the lane meant.
#
# A TBD NO RECORD COVERS IS REPORTED, NOT INVENTED. It is left out of the
# output with its name, and expect.rb then reports it as still TBD.
#
# Values are read the way run.rb exposes a record: every entry of `keys` under
# its own dotted name, the document fields `outcome`, `rc` and `ended`, and the
# derived `faults.raised`. A key the record does not carry is an error here, as
# it is there: the expectation asserts something that run cannot answer, and
# writing a guess would hide it.

require "json"

EXPECT_COLUMNS = %w[#case_id key rule value origin].freeze
CASE_COLUMNS = %w[case_id lane route mode control demo frames variant requires judged_against tiers origin].freeze
CASES = "tests/doom-core/cases/frame.tsv".freeze
TBD = "TBD".freeze

USAGE = "usage: fills.rb --expect UNFILLED.tsv --records DIR [--records DIR ...] " \
        "[--cases FILE] [--out FILE]".freeze

def fail_with(message)
  abort("fills.rb: #{message}")
end

# The same TSV rule as the rest of the layer: "#" lines are the file's own
# header, except the one naming the columns, which is checked and not read by
# position.
def read_tsv(path, columns, who)
  File.exist?(path) or fail_with("no #{who} at #{path}")
  rows = []
  File.readlines(path, chomp: true).each_with_index do |line, i|
    next if line.empty?
    if line.start_with?("#")
      fields = line.split("\t")
      next unless fields.first == columns.first
      fields == columns or
        fail_with("#{path} has the columns #{fields.join(' ')}, not #{columns.join(' ')}")
      next
    end
    fields = line.split("\t", -1)
    fields.length == columns.length or
      fail_with("#{path}:#{i + 1} has #{fields.length} fields, not #{columns.length}")
    rows << fields
  end
  rows.empty? and fail_with("#{path} holds no rows")
  rows
end

# The expectation's TBD rows, in file order: [case_id, key, rule].
def read_tbd(path)
  rows = read_tsv(path, EXPECT_COLUMNS, "expectation")
  tbd = rows.select { |_id, _key, _rule, value, _origin| value == TBD }
  tbd.empty? and
    fail_with("#{path} holds no #{TBD} row, so a fills file for it would be empty. Point --expect at the " \
              "expectation as harness/expect.rb generates it WITHOUT --fills; the tracked one is already filled")
  tbd.map { |id, key, rule, _value, _origin| [id, key, rule] }
end

def read_cases(path)
  rows = read_tsv(path, ["#" + CASE_COLUMNS.first] + CASE_COLUMNS[1..], "case matrix")
  rows.to_h { |r| [r[0], CASE_COLUMNS.zip(r).to_h] }
end

# run.rb names a record after the case, with the characters a path cannot hold
# replaced; the same rule is applied here so the two agree on the file name.
def record_name(case_id)
  case_id.to_s.gsub(%r{[/\\\s]}, "_") + ".json"
end

# case_id -> [document, "<run dir>/records/<file>"]. A case whose record two run
# directories both hold is refused: they could disagree, and nothing here could
# choose.
def read_records(dirs)
  found = {}
  dirs.each do |dir|
    records = File.join(dir, "records")
    File.directory?(records) or
      fail_with("#{dir} holds no records/ directory; --records names a run directory, the one a run had as " \
                "HARNESS_RUN")
    Dir.children(records).sort.each do |name|
      next unless name.end_with?(".json")
      case_id = name.delete_suffix(".json")
      from = File.join(File.basename(dir.chomp(File::SEPARATOR)), "records", name)
      if (already = found[case_id])
        fail_with("two run directories hold a record for #{case_id}: #{already[1]} and #{from}. Give the one " \
                  "run the values must come from; two runs could disagree and nothing here could choose")
      end
      doc = begin
        JSON.parse(File.read(File.join(records, name)))
      rescue JSON::ParserError => e
        fail_with("the record at #{from} is not JSON: #{e.message}")
      end
      doc.is_a?(Hash) or fail_with("the record at #{from} is not a document")
      found[case_id] = [doc, from]
    end
  end
  found.empty? and fail_with("no record was found under #{dirs.join(', ')}")
  found
end

# The record must be this case's own run, checked the way run.rb checks it
# before judging. A refusal is held to the route alone: mode, control and the
# requested count are only parsed by a run that got that far.
def identify(doc, kase, from)
  id = kase["case_id"]
  %w[completed refused].include?(doc["outcome"]) or
    fail_with("#{id}: the record at #{from} ended as #{doc['outcome'].inspect}, which is neither completed " \
              "nor refused, so it is not a run any value may be taken from")
  doc["route"] == kase["route"] or
    fail_with("#{id}: the record at #{from} says the route was #{doc['route'].inspect}, and the matrix row " \
              "declares #{kase['route'].inspect}")
  return unless doc["outcome"] == "completed"
  { "mode" => kase["mode"], "control" => kase["control"] }.each do |field, want|
    doc[field] == want or
      fail_with("#{id}: the record at #{from} says #{field} was #{doc[field].inspect}, and the matrix row " \
                "declares #{want.inspect}")
  end
  doc["requested_tics"].to_s == kase["frames"] or
    fail_with("#{id}: the record at #{from} was asked for #{doc['requested_tics'].inspect} tics, and the " \
              "matrix row declares #{kase['frames']}")
end

# What an expectation may name, exactly as run.rb exposes it.
def exposed(doc, from)
  keys = doc["keys"].is_a?(Hash) ? doc["keys"] : {}
  collisions = keys.keys & %w[outcome rc ended faults.raised]
  collisions.empty? or
    fail_with("the record at #{from} holds #{collisions.join(', ')} among its keys, which an expectation " \
              "could not name unambiguously")
  values = keys.dup
  %w[outcome rc ended].each { |f| values[f] = doc[f] if doc.key?(f) }
  faults = keys.select { |k, v| k.start_with?("faults.") && v.is_a?(Integer) }
  unless faults.empty?
    values["faults.raised"] = faults.select { |_, v| v.positive? }.keys
                                    .map { |k| k.delete_prefix("faults.") }.sort
  end
  values
end

# One TBD's value, as the fills file's text. A `set` row holds a comma-separated
# set, and every other rule holds the value itself.
def cell(rule, value, case_id, key, from)
  text = rule == "set" ? Array(value).map(&:to_s).sort.join(",") : value.to_s
  text.empty? and
    fail_with("#{case_id}: #{key} is empty in the record at #{from}, and an empty cell fills nothing")
  text.include?("\t") and
    fail_with("#{case_id}: #{key} holds a tab in the record at #{from}, which no column of this file can carry")
  text == TBD and
    fail_with("#{case_id}: #{key} is the literal string #{TBD} in the record at #{from}")
  text
end

def parse(argv)
  o = { expect: nil, cases: CASES, records: [], out: nil }
  args = argv.dup
  until args.empty?
    flag = args.shift
    value = args.shift or fail_with("#{flag} needs a value")
    case flag
    when "--expect" then o[:expect] = value
    when "--cases" then o[:cases] = value
    when "--records" then o[:records] << value
    when "--out" then o[:out] = value
    else abort(USAGE)
    end
  end
  o[:expect] && !o[:records].empty? or abort(USAGE)
  o
end

def main # rubocop:disable Metrics/MethodLength
  o = parse(ARGV)
  tbd = read_tbd(o[:expect])
  cases = read_cases(o[:cases])
  records = read_records(o[:records])

  used = {}
  rows = []
  uncovered = []
  tbd.each do |case_id, key, rule|
    kase = cases[case_id] or
      fail_with("#{o[:expect]} has a #{TBD} for #{case_id}, which #{o[:cases]} does not declare")
    got = records[case_id]
    unless got
      uncovered << [case_id, key]
      next
    end
    doc, from = got
    identify(doc, kase, from) unless used[case_id]
    values = (used[case_id] ||= exposed(doc, from))
    values.key?(key) or
      fail_with("#{case_id}: the expectation asserts #{key}, and the record at #{from} does not carry it; " \
                "that is what run.rb calls an error, and a value written here would hide it")
    rows << [case_id, key, cell(rule, values[key], case_id, key, from), from]
  end

  rows.sort_by! { |r| [r[0], r[1]] }
  out = +"# the values that fill the frame lane's expectation, read out of result records by\n"
  out << "# tests/doom-core/harness/fills.rb. harness/expect.rb --fills substitutes each row's value\n"
  out << "# for that key's TBD; `from` names the run directory and the record it was read out of.\n"
  out << "# Nothing here is typed: regenerate it from the records rather than editing a cell.\n"
  out << "# tbd\t#{tbd.length}\n"
  out << "# filled\t#{rows.length}\n"
  out << "# uncovered\t#{uncovered.length}\n"
  used.keys.sort.each do |case_id|
    doc, from = records[case_id]
    out << "# record\t#{from}\t#{doc['started']}\t#{doc['route']} #{doc['mode']} #{doc['control']} " \
           "#{doc['requested_tics']} tics\t#{doc['outcome']} rc=#{doc['rc']}\n"
  end
  uncovered.sort.each { |case_id, key| out << "# uncovered\t#{case_id}\t#{key}\n" }
  out << %w[#case_id key value from].join("\t") << "\n"
  rows.each { |r| out << r.join("\t") << "\n" }
  o[:out] ? File.write(o[:out], out) : print(out)

  warn("fills.rb: #{rows.length} of #{tbd.length} #{TBD} rows filled from #{used.length} record(s)" \
       "#{", #{uncovered.length} uncovered" unless uncovered.empty?}")
  uncovered.sort.each { |case_id, key| warn("fills.rb:   no record for #{case_id}\t#{key}") }
end

main
