#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tests/doom/gate-r007-golden.rb — G0: does a freshly built reference still
# produce the frame hashes the recorded golden has?
#
#   gate-r007-golden.rb --built DIR/frames.tsv [--golden FILE] [--allowances FILE]
#
# This is a **separate gate** from tests/doom/compare.rb, and the E052
# comparison does not stand in for it.  They answer different questions and read
# different hashes:
#
#   compare.rb  does the PORT match the REFERENCE?  Reads the E052 dump hook's
#               five-column frames.tsv, whose fnv1a64 uses the correct FNV-1a
#               offset basis.
#   this gate   does a REBUILT reference match the RECORDED one?  Reads the R007
#               headless harness's four-column output, whose fnv1a64 uses the
#               nonstandard basis 1469598103934665603 -- one digit short, and
#               preserved deliberately because the golden was computed with it.
#
# Both columns are called `fnv1a64` and both sit at index 2.  They are different
# functions and their values must never be compared across the two files.  See
# tests/doom/reference/NOTICE.md.
#
# The golden is never regenerated.  There is no flag that would, and a
# divergence is reported rather than absorbed.

require "set"

GOLDEN_HEADER = %w[frame gametic fnv1a64 sha256].freeze

class GateFailure < StandardError; end

def read_text(path)
  File.binread(path).force_encoding("UTF-8").gsub(/\r\n?/, "\n")
end

def read_frames(path, label)
  raise GateFailure, "#{label}: no such file: #{path}" unless File.exist?(path)

  raw = read_text(path)
  raise GateFailure, "#{label}: #{path} is empty" if raw.empty?

  header = nil
  rows = []
  raw.split("\n", -1).each do |line|
    next if line.empty?

    if line.start_with?("#")
      header ||= line[1..].split("\t", -1)
      next
    end
    rows << line.split("\t", -1)
  end
  raise GateFailure, "#{label}: #{path} has no header" if header.nil?
  raise GateFailure, "#{label}: #{path} has no data rows" if rows.empty?

  if header != GOLDEN_HEADER
    raise GateFailure, "#{label}: header is #{header.inspect}, want #{GOLDEN_HEADER.inspect}. " \
                       "The five-column E052 layout is a different file with a different hash " \
                       "function; it must not be compared against this golden."
  end
  rows.each_with_index do |r, i|
    next if r.size == header.size

    raise GateFailure, "#{label}: row #{i} has #{r.size} fields, the header declares #{header.size}"
  end
  [header, rows]
end

def validate(rows, label)
  ids = rows.each_with_index.map do |r, i|
    Integer(r[0], 10)
  rescue ArgumentError
    raise GateFailure, "#{label}: row #{i} has a non-integer frame id #{r[0].inspect}"
  end
  gts = rows.each_with_index.map do |r, i|
    Integer(r[1], 10)
  rescue ArgumentError
    raise GateFailure, "#{label}: row #{i} has a non-integer gametic #{r[1].inspect}"
  end

  # The frame number is the record identity: unique, increasing, and contiguous,
  # because s_frameno++ advances once per dump.  The gametic is a grouping key
  # and repeats legitimately whenever the engine drew more than once for a tic.
  ids.each_cons(2).with_index do |(a, b), i|
    raise GateFailure, "#{label}: frame id #{a} repeats at row #{i + 1}" if a == b
    raise GateFailure, "#{label}: frame ids are not increasing at row #{i + 1}: #{a} then #{b}" if b < a
    raise GateFailure, "#{label}: frame ids jump from #{a} to #{b} at row #{i + 1}" if b > a + 1
  end
  gts.each_cons(2).with_index do |(a, b), i|
    raise GateFailure, "#{label}: gametic goes backwards at row #{i + 1}: #{a} then #{b}" if b < a
  end
  [ids, gts]
end

Allow = Struct.new(:frame, :field, :golden, :built, :reason, :fired)

def read_allowances(path)
  return [] if path.nil?
  raise GateFailure, "allowances: no such file: #{path}" unless File.exist?(path)

  out = []
  read_text(path).split("\n", -1).each_with_index do |line, i|
    next if line.empty? || line.start_with?("#")

    f = line.split("\t", -1)
    raise GateFailure, "allowances: line #{i + 1} has #{f.size} fields, want 5 " \
                       "(frame, field, golden value, built value, reason)" if f.size != 5
    raise GateFailure, "allowances: line #{i + 1} has an empty reason" if f[4].strip.empty?
    raise GateFailure, "allowances: line #{i + 1} declares the same value on both sides" if f[2] == f[3]

    out << Allow.new(Integer(f[0], 10), f[1], f[2], f[3], f[4], false)
  end
  out
end

def main(argv)
  built = golden = allowpath = nil
  report_all = false
  until argv.empty?
    case (a = argv.shift)
    when "--built"      then built = argv.shift
    when "--golden"     then golden = argv.shift
    when "--allowances" then allowpath = argv.shift
    when "--report-all" then report_all = true
    else
      warn "gate-r007-golden: unknown argument #{a.inspect}"
      return 2
    end
  end
  golden ||= File.join(__dir__, "fixtures", "reference", "demo1_hashes.tsv")
  if built.nil?
    warn "usage: gate-r007-golden.rb --built DIR/frames.tsv [--golden FILE] " \
         "[--allowances FILE] [--report-all]"
    return 2
  end

  collected = []
  begin
    allowances = read_allowances(allowpath)
    _gh, grows = read_frames(golden, "golden")
    _bh, brows = read_frames(built, "built")
    gids, = validate(grows, "golden")
    bids, = validate(brows, "built")

    if grows.size != brows.size
      raise GateFailure, "the golden has #{grows.size} frames, the built reference has #{brows.size}"
    end
    if gids != bids
      raise GateFailure, "the frame id sequences differ: golden #{gids.first}..#{gids.last}, " \
                         "built #{bids.first}..#{bids.last}"
    end

    # The sha256 column is "-" unless the reference was built with CommonCrypto.
    # That is a build difference, not a divergence, so it is reported as a
    # skipped column rather than counted as agreement or quietly ignored.
    gsha = grows.count { |r| r[3] != "-" }
    bsha = brows.count { |r| r[3] != "-" }
    sha_comparable = gsha == grows.size && bsha == brows.size

    diffs = 0
    grows.each_with_index do |g, i|
      b = brows[i]
      fields = { "gametic" => 1, "fnv1a64" => 2 }
      fields["sha256"] = 3 if sha_comparable
      fields.each do |name, col|
        next if g[col] == b[col]

        a = allowances.find { |x| x.frame == gids[i] && x.field == name && x.golden == g[col] && x.built == b[col] }
        if a
          a.fired = true
          next
        end
        diffs += 1
        msg = "frame #{gids[i]} (gametic #{g[1]}): #{name} golden=#{g[col]} built=#{b[col]}"
        raise GateFailure, msg unless report_all

        collected << [gids[i], name, g[col], b[col]]
      end
    end

    stale = allowances.reject(&:fired)
    unless stale.empty?
      d = stale.map { |x| "frame #{x.frame}:#{x.field}" }.join(", ")
      raise GateFailure, "#{stale.size} declared discrepancy(ies) did not occur: #{d}"
    end

    note = sha_comparable ? "" : " (sha256 not compared: #{gsha}/#{grows.size} golden and " \
                                 "#{bsha}/#{brows.size} built rows carry one -- a CommonCrypto build difference)"
    if collected.empty? && diffs.zero?
      puts "G0: OK (#{grows.size} frames identical#{note})"
      return 0
    end

    puts "G0: DIVERGES (#{collected.size} field(s) across #{collected.map(&:first).uniq.size} frame(s))#{note}"
    collected.each do |frame, field, gv, bv|
      puts "#{frame}\t#{field}\t#{gv}\t#{bv}\tTODO: record why this differs"
    end
    puts "G0: FAILED (--report-all lists them; it does not excuse them)"
    1
  rescue GateFailure => e
    puts "G0: FAILED #{e.message}"
    1
  end
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
