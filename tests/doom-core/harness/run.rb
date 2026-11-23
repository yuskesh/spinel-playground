#!/usr/bin/env ruby
# tests/doom-core/harness/run.rb — the frame lane's case runner: decision 0009
# items 4, 5, 7 and 9.
#
#   HARNESS_RUN=DIR ruby tests/doom-core/harness/run.rb [SELECTION] [OPTIONS]
#
# It selects cases from the declared matrix, runs each one as ONE
# source-port.rb process with a result record, judges that record against the
# tracked expectations, and writes a summary as JSON and as JUnit XML. It
# builds nothing: every artifact a route needs is named through the
# environment, so no tracked file holds a host path.
#
# SELECTION, by any column of the matrix (0009 item 4):
#   --tier T   --route R   --control C   --case ID   --lane L   --mode M
#   --demo D   --frames N  --variant V   --requires P --judged-against ID
#   --origin O
# A flag may be repeated and may take a comma-separated list; the values of one
# flag are a union and different flags intersect. `--tier` and `--requires`
# test membership of the row's set; every other column is an exact match.
# SELECTING NOTHING IS AN ERROR, never a silent pass.
#
# TWO TIERS ARE NOT ORDINARY CASES, and selection holds them apart from the
# rest. Both rules apply to every selection, `--list` included:
#   retired   NEVER selected and never listed, by any selection. A retired row
#             is the RECORD that a pinned check was deliberately not migrated,
#             carrying its reason in `origin`, which 0009's Validation requires
#             of every check retired rather than migrated. It judges nothing --
#             its `judged_against` is `-` -- so running one could only ever
#             error, and that error would read as a harness fault when it is a
#             selection fault. `--tier retired` is REFUSED rather than answered
#             with an empty selection, so the rule is visible where it is hit.
#   selftest  selected ONLY where `--tier selftest` names it, never by a route,
#             control, lane or any other selection alone. These are the
#             harness's own tests: several of them are meant to end as fail or
#             error, so picking one up by route would report the harness's own
#             probe as a lane regression. That same selection runs the two
#             ACCOUNTING STEPS below, which are not rows of the matrix at all.
#
# OPTIONS:
#   --jobs N        the concurrency cap, default 1 (item 4). It is a budget:
#                   heavy runs are serialized outside this process.
#   --list          print the selected case ids and stop. It selects, applies
#                   the two tier rules above and prints, without HARNESS_RUN
#                   and without reading the expectations.
#   --matrix PATH   the case matrix, default tests/doom-core/cases/frame.tsv
#   --expect PATH   the expectations, default tests/doom-core/expect/frame.tsv
#   --driver D      `minitest` (default) or `plain`. Both schedule the same
#                   cases and write the same reports; see THE RUNNER below.
#
# THE ENVIRONMENT. `HARNESS_RUN` is required by every run and names a per-run
# directory; this file creates `records/`, `text/`, `fixtures/` and `trees/`
# inside it and writes `summary.json` and `junit.xml` there (item 7).
# `REQUIRE_ALL=1` turns every skip into a failure (item 7). `RUBY` names the
# interpreter for the child runs, defaulting to this one. The artifacts and
# inputs a route needs are named by the variables in PREREQUISITES below.
#
# THE FOUR VERDICTS (item 7), and nothing else:
#   pass   every expectation row for the case is satisfied.
#   fail   at least one row differs; the differing keys are printed one per
#          line with the rule, the expected value and what the record held.
#   error  no record; an `outcome` that is neither completed nor refused,
#          which is what a killed or signalled run leaves; a record that is
#          not this case's run; an expectation naming something the record
#          does not carry; no expectation rows at all; or a case whose own
#          declaration cannot be run. An interrupted case is never pass or
#          fail.
#   skip   a prerequisite is missing, and the skip NAMES it.
#
# Two selftests are DESIGNED to end in something other than pass, and the
# runner declares which verdict each must reach, so that reaching it is that
# case passing (see DECLARED VERDICTS below):
#   frame.ruby.none.599       must FAIL: a nominal one frame short must not
#                             pass the 600-frame expectation on a subset.
#   frame.ruby.none.600.kill  must ERROR: a run killed by a signal is never
#                             reported as a pass or a failure.
# So `--tier selftest` exits 0 when every selftest did what it is designed to
# do, and 1 when one of them did not.
#
# WHAT AN EXPECTATION MAY NAME. Every entry of the record's `keys`, under its
# own dotted name; the document fields `outcome`, `rc` and `ended`; and
# `faults.raised`, which this file DERIVES as the sorted names of the fault
# kinds the record counts above zero. `faults.raised` exists only where the
# record carries at least one `faults.*` key: asserting it against a report
# that printed no faults line is an error, not an empty set.
#
# MUTATION CASES (item 8), AND THE INVERSION EVERY READER MUST HOLD ONTO. A
# case whose variant begins `mutate=` deletes a named piece of the CORE source
# in a PRIVATE COPY of the tree, under `trees/` in the run directory, and runs
# the copy. The worktree is never written. Such a case is judged against the
# NOMINAL it perturbs, and its whole point is that the nominal's expectation
# must NOTICE the deletion, so its verdict is INVERTED against every other
# case's:
#
#   the expectation FAILING  =>  the mutation was detected  =>  the case PASSES
#   the expectation PASSING  =>  nothing detected it        =>  the case FAILS
#
# Read that twice before changing this file: for every other case, a differing
# expectation row is a failure. A mutation case that passes its nominal's
# expectation is the failure mode this case exists to catch -- the vacuous
# comparison of 0009's evidence item 3, where deleting `dc_clear_planes`' writes
# at `44a7d4b` left 600 frames byte-identical to the pinned nominal and no
# control noticed. A mutation whose edit matched NOTHING in the source is an
# `error`, never a pass: an edit that changed no byte proves nothing, and the
# run that followed it was the nominal run under another name.
#
# DECLARED VERDICTS: CASES DESIGNED TO END IN SOMETHING OTHER THAN PASS. The
# mutation inversion is one shape of the same idea, and two more selftests need
# it: 0009's Validation requires that "a nominal run shortened by one frame
# fails" and that "a case killed by a signal reports error, not pass or fail".
# Those two cases have therefore DONE THEIR JOB when they fail and when they
# error, and `DESIGNED_VERDICTS` in this file says so, one line per case:
#
#   the declared verdict REACHED      =>  the case did its job  =>  it PASSES
#   any other verdict                 =>  it did not            =>  it FAILS
#
# So `--tier selftest` exits 0 when every selftest did what it is designed to
# do, and exits 1 otherwise, instead of always exiting 1 and leaving a reader to
# work out from prose which failures were the intended ones. The reason text of
# such a case says which way round it is being read, and `summary.json` carries
# `expected_verdict` and `as_designed` beside the verdict, so a report reading
# the document never has to infer it either. A `skip` is left alone: a missing
# prerequisite means nothing ran, so the case reached no verdict to compare.
#
# THE SELFTEST TIER ALSO RUNS TWO STEPS THAT ARE NOT CASES (0009's clarification
# "the accounting runs inside a tier"). `--tier selftest` runs the harness's own
# bookkeeping beside the harness's own tests: the tracked frozen pins, and the
# case matrix checked against them. They are steps and not rows -- no matrix
# declares them, nothing selects them by column and no expectation judges them --
# but each leaves a Result row carrying one of the four verdicts above, so the
# totals, the JUnit document and the no-fail-and-no-error gate count them exactly
# as they count a case, and a green gate cannot mean the accounting was skipped.
#
#   selftest.pins-tracked      the tracked expect/pins.tsv names the frozen
#                              revision and the tick.sh blob this file holds, and
#                              cases.rb accounts for every pin over it with no
#                              problems.
#   selftest.pins-regenerate   pins.rb at the frozen revision reproduces that
#                              file byte for byte. It SKIPS where the revision
#                              does not resolve, and the skip says what is lost
#                              with it.
#
# ONE OF THE TWO NEEDS THE REPOSITORY'S HISTORY AND THE OTHER NEEDS NONE, which
# is why only one of them carries a prerequisite at all. THE ACCOUNTING STEPS,
# further down this file, says where that line comes from, why the git call sits
# on one side of it, and why the prerequisite is the revision resolving rather
# than git being installed.
#
# THE RUNNER (item 9). minitest is the scheduling shell: one test method per
# case, `parallelize_me!` for the threads, and the cap held by this file's own
# gate so it does not depend on which knob a minitest version reads. Selection,
# running, judging and reporting are plain Ruby above it and touch no minitest
# API, so `--driver plain` runs the same cases and writes the same reports
# without it. Only what both recorded lines provide is used: Ruby 3.3.8 with
# minitest 5.20.0 on Debian and Ruby 3.4.1 with minitest 5.25.5 on macOS.

# RETIRED (docs/decisions/0009, "Clarification (2026-09-17)"): every case this
# runs is a source-port.rb run beside the original, and those lanes are frozen
# at 0af8ba0, superseded by tests/doom-core/verify.sh on the real entries
# (tests/doom-core/harness/retired.sh). STAGE1_LANES=run runs them anyway.
unless ENV["STAGE1_LANES"] == "run"
  puts "run.rb: RETIRED -- the frame lane's cases are frozen at 0af8ba0 (0009, 2026-09-17); " \
       "superseded by tests/doom-core/verify.sh on the real entries, the boundary copy refunded; " \
       "reproduce with: git checkout 0af8ba0"
  exit 0
end

require "json"
require "fileutils"
require "open3"
require "rbconfig"

module Harness
  ROOT = File.expand_path("../../..", __dir__)

  # The matrix's columns are the contract between it and this file; its rows
  # are not. A matrix whose header is anything else is refused rather than
  # read by position.
  COLUMNS = %w[case_id lane route mode control demo frames variant requires judged_against tiers origin].freeze
  # Columns whose cell is a comma-separated set, matched by membership.
  SET_COLUMNS = %w[tiers requires].freeze
  # The two tiers selection holds apart from the rest; see the header.
  RETIRED_TIER = "retired"
  SELFTEST_TIER = "selftest"
  RULES = %w[eq gt0 set].freeze
  # Where an expectation value came from: a frozen tick.sh pin, or a first run
  # of a case no old pin asserts. The file carries it so a review can see which
  # rows no old verdict stands behind.
  #
  # `run@REVISION` is the third: a value that DID stand on a pin and no longer
  # does, moved by expect.rb --overrides because the port changed, with the
  # commit that moved it named in the origin itself. The runner judges by none
  # of the three; it refuses an origin it does not recognize so that a row
  # carrying no reviewed provenance cannot slip into the file.
  ORIGINS = %w[pin run].freeze
  ORIGIN = /\A(?:pin|run(?:@[0-9a-f]{7,40})?)\z/.freeze

  # WHAT EACH PREREQUISITE IS, AND WHICH VARIABLE NAMES IT. A case's `requires`
  # column names these one at a time, so a skip says which one is missing. They
  # are what a case WAITS ON, not what built it: stage 1 has no artifact cache --
  # that is item 6, stage 3 -- and this runner builds nothing, so the thing that
  # can be absent is the built object, never the kernel that made it.
  PREREQUISITES = {
    "wad" => { env: "WAD", kind: :file, what: "the IWAD",
               default: -> { File.join(ROOT, "build/doom-wad/doom1.wad") } },
    "source-lib" => { env: "HARNESS_SOURCE_LIB", kind: :file,
                      what: "the shared object linking the kernel tool's objects for the source contracts",
                      default: -> {} },
    "adapter-lib" => { env: "HARNESS_ADAPTER_LIB", kind: :file,
                       what: "the shared object linking the adapter and the kernel tool's objects",
                       default: -> {} },
    "session-dir" => { env: "HARNESS_SESSION_DIR", kind: :dir,
                       what: "the generated session layout, the directory holding buffers.tsv and slots.tsv",
                       default: -> {} }
  }.freeze

  # The field map the session and adapter routes are handed when no variant
  # replaces it. It is tracked, so it is named here and not in the environment.
  FIELDS = File.join(ROOT, "tests/doom-core/fixtures/source/fields.tsv")

  # How long a `kill` case runs before the signal. It must land inside the run
  # and not after it; a run that ended first is an error, not a killed case.
  KILL_AFTER_S = Float(ENV["HARNESS_KILL_AFTER_S"] || "2.0")

  # WHAT A MUTATION CASE COPIES. `source-port.rb` takes its own root from its
  # own directory -- `ROOT = File.expand_path("../..", __dir__)` -- and reads
  # only these three subtrees under it, so copying them and running the copy's
  # `source-port.rb` runs the mutated source with nothing else changed. A path
  # outside them would fail the copy's run outright rather than reach back into
  # the worktree, which is the behaviour to keep: silently reading the unmutated
  # file is what would make the case vacuous.
  TREE_SUBDIRS = %w[examples/doom tests/doom-core tools/doom].freeze

  # THE MUTATIONS (item 8). Each one deletes an exact, contiguous run of LINES
  # of the CORE source, written out here as they stand in the file, indentation
  # included, and matched literally. The run must appear EXACTLY once, so
  # neither a moved line nor a second occurrence can turn the deletion into
  # something other than what `what` says. They are anchored on the text they
  # delete and never on line numbers, so an edit above them cannot silently move
  # the cut elsewhere: it makes the case error instead.
  Mutation = Struct.new(:file, :what, :lines, keyword_init: true) do
    def cut = /^#{lines.map { |l| Regexp.escape(l) }.join("\n")}\n/
  end
  MUTATIONS = {
    # The 44a7d4b vacuity itself: `dc_clear_planes`' four counter writes.
    "clear-counters" => Mutation.new(
      file: "examples/doom/core/src/planes.rb",
      what: "dc_clear_planes' four counter writes, to i_lastvisplane, i_lastopening, i_floorplane and i_ceilingplane",
      lines: ["  state[i_lastvisplane] = 0",
              "  state[i_lastopening] = 0",
              "  state[i_floorplane] = -1",
              "  state[i_ceilingplane] = -1"]
    ),
    # The clip loop. Its BODY is what tells it from the row-cache loop a few
    # lines below, which has the same head and the same counter.
    "clear-clips" => Mutation.new(
      file: "examples/doom/core/src/planes.rb",
      what: "dc_clear_planes' loop over the view's width, which writes floorclip and ceilingclip",
      lines: ["  i = 0",
              "  while i < w",
              "    floorclip[i] = viewheight[0]",
              "    ceilingclip[i] = -1",
              "    i += 1",
              "  end"]
    )
  }.freeze

  # THE VERDICT A CASE IS DESIGNED TO REACH, where that is not `pass`. See
  # CASES DESIGNED TO END IN SOMETHING OTHER THAN PASS in the header. Each entry
  # is the verdict the case must reach and WHY that is the point of the case;
  # reaching it makes the case pass, and reaching any other verdict makes it
  # fail. It is keyed by case id and not by variant: `kill` is a variant, but
  # "one frame short" is only the matrix's frame count, and there is nothing in
  # a 599 that a runner could recognise as a shortened nominal by itself.
  DESIGNED_VERDICTS = {
    "frame.ruby.none.599" => [
      "fail",
      "0009's Validation requires that a nominal run shortened by one frame fails rather than passing on a " \
      "subset, so this case runs 599 frames against the 600-frame nominal's expectation and must FAIL it"
    ],
    "frame.ruby.none.600.kill" => [
      "error",
      "0009 item 7 and its Validation require that a case killed by a signal reports error and is never " \
      "counted as pass or fail, so this case is killed mid-run and must ERROR"
    ]
  }.freeze

  # THE FROZEN PINS' IDENTITY, held here so that the tracked file is checked
  # against something and not only against itself. `expect/pins.tsv` is what
  # `pins.rb` extracted from `tick.sh` at the stage 1 freeze, and the frame
  # lane's expectations were taken from that extraction; a pins file naming any
  # other revision, or the same revision with another tick.sh behind it, does
  # not stand behind them whatever else it is right about. The blob is named as
  # well as the commit because a revision alone says which history was read and
  # not which file: the two together are the identity the accounting asserts.
  PINS = File.join(ROOT, "tests/doom-core/expect/pins.tsv")
  PINS_REVISION = "e2f5676"
  PINS_COMMIT = "e2f5676aea6f2f842aa263af582fec18d7383278"
  PINS_TICK = "tests/doom-core/tick.sh"
  PINS_TICK_BLOB = "622db93ac43433f2fec7b7a9cfd077252952f0a3"
  PINS_RB = File.join(ROOT, "tests/doom-core/harness/pins.rb")
  CASES_RB = File.join(ROOT, "tests/doom-core/harness/cases.rb")

  class Refusal < StandardError; end   # a bad input: the whole run stops
  class CaseError < StandardError; end # one case's `error` verdict

  Case = Struct.new(*COLUMNS.map(&:to_sym))

  class Case
    def requires_list
      self["requires"].to_s.split(",").reject { |p| p.empty? || p == "-" }
    end

    def tiers_list
      self["tiers"].to_s.split(",").reject { |t| t.empty? || t == "-" }
    end

    def frames_i
      Integer(self["frames"], 10)
    rescue ArgumentError, TypeError
      raise CaseError, "the case declares frames #{self['frames'].inspect}, which is not a count"
    end

    def retired? = tiers_list.include?(RETIRED_TIER)
    def selftest? = tiers_list.include?(SELFTEST_TIER)

    # The name of the mutation this case applies, or nil. It is the ONE thing
    # that inverts the verdict, so it is asked in one place.
    def mutation
      v = self["variant"].to_s
      v.start_with?("mutate=") ? v.delete_prefix("mutate=") : nil
    end
  end

  # ---------------------------------------------------------------- the matrix
  module Matrix
    def self.read(path)
      File.exist?(path) or raise Refusal, "no case matrix at #{path}"
      header = nil
      rows = []
      File.readlines(path, chomp: true).each_with_index do |line, i|
        next if line.empty?
        if line.start_with?("#")
          next unless line.start_with?("#case_id")
          header = line.sub(/\A#/, "").split("\t", -1)
          next
        end
        cells = line.split("\t", -1)
        rows << [i + 1, cells]
      end
      header or raise Refusal, "#{path} has no `#case_id` header line"
      header == COLUMNS or
        raise Refusal, "#{path} declares the columns #{header.join(',')}; this runner reads #{COLUMNS.join(',')}"
      rows.empty? and raise Refusal, "#{path} holds no case rows"
      cases = rows.map do |lineno, cells|
        cells.length == COLUMNS.length or
          raise Refusal, "#{path}:#{lineno} has #{cells.length} columns, not #{COLUMNS.length}"
        Case.new(*cells)
      end
      dup = cases.map { |c| c["case_id"] }.tally.find { |_, n| n > 1 }
      dup and raise Refusal, "#{path} declares the case #{dup[0]} #{dup[1]} times"
      cases
    end

    # filters: column => [value, ...]. One flag's values are a union, different
    # flags intersect.
    #
    # Two rules come BEFORE the filters and no selection can reach past them
    # (see the header): a retired row is never a case, and a selftest row is a
    # case only where `--tier selftest` asked for it. They are applied here, in
    # the one place every selection and `--list` goes through, so that no caller
    # can select a retirement by naming some other column.
    def self.select(cases, filters)
      tiers = filters.fetch("tiers", [])
      if tiers.include?(RETIRED_TIER)
        raise Refusal, "--tier #{RETIRED_TIER} selects nothing: a retired row is the record that a pinned check " \
                       "was deliberately not migrated, with its reason in `origin`, and judges nothing. " \
                       "Read those rows in the matrix; they are never run"
      end
      selectable = cases.reject(&:retired?)
      selectable = selectable.reject(&:selftest?) unless tiers.include?(SELFTEST_TIER)
      filters.inject(selectable) do |kept, (column, wanted)|
        kept.select do |c|
          if SET_COLUMNS.include?(column)
            (c.public_send(:[], column).to_s.split(",") & wanted).any?
          else
            wanted.include?(c.public_send(:[], column).to_s)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------- the expectations
  # case_id, key, rule, value. Rows are grouped by the case they judge, which
  # is a case's `judged_against` column and not always the case itself.
  module Expectations
    Row = Struct.new(:case_id, :key, :rule, :value, :lineno)

    def self.read(path)
      File.exist?(path) or raise Refusal, "no expectations at #{path}"
      by_case = Hash.new { |h, k| h[k] = [] }
      seen = {}
      File.readlines(path, chomp: true).each_with_index do |line, i|
        lineno = i + 1
        next if line.empty? || line.start_with?("#")
        cells = line.split("\t", -1)
        # The fifth column is the row's provenance -- whether its value came from
        # a frozen pin, from a first run, or from a run at the revision that
        # moved it off its pin. It is the file's own record of that,
        # reviewed there, and nothing the runner judges by; it must be present so
        # that a row without one cannot slip in, and is not read here.
        cells.length == 5 or raise Refusal, "#{path}:#{lineno} has #{cells.length} columns, not 5"
        case_id, key, rule, value, origin = cells
        ORIGIN.match?(origin) or
          raise Refusal, "#{path}:#{lineno} names the origin #{origin.inspect}; they are " \
                         "#{ORIGINS.join(', ')}, and run@REVISION for a value expect.rb --overrides " \
                         "moved off its pin"
        RULES.include?(rule) or
          raise Refusal, "#{path}:#{lineno} names the rule #{rule.inspect}; the rules are #{RULES.join(', ')}"
        if (first = seen[[case_id, key]])
          raise Refusal, "#{path}:#{lineno} asserts #{key} for #{case_id} again; it was already " \
                         "asserted at line #{first}"
        end
        seen[[case_id, key]] = lineno
        by_case[case_id] << Row.new(case_id, key, rule, value, lineno)
      end
      by_case.empty? and raise Refusal, "#{path} holds no expectation rows"
      # Without the default block: several cases read this map at once, and a
      # lookup that inserts is a race, not a read.
      by_case.to_h
    end
  end

  # ------------------------------------------------------------- the judgement
  Difference = Struct.new(:key, :rule, :expected, :record, :detail) do
    # One line, never two joined strings (item 5 / 0009 item 2).
    def to_line
      s = format("%-40s rule=%-3s expected=%s record=%s", key, rule, expected.inspect, record.inspect)
      detail ? "#{s} #{detail}" : s
    end

    def to_h
      { "key" => key, "rule" => rule, "expected" => expected, "record" => record, "detail" => detail }
    end
  end

  module Judge
    # The record's own keys, plus the document fields expectations may name,
    # plus the derived set. Returns [values, absent-names-are-not-in-it].
    def self.exposed(doc)
      keys = doc["keys"].is_a?(Hash) ? doc["keys"] : {}
      collisions = keys.keys & %w[outcome rc ended faults.raised]
      collisions.empty? or
        raise CaseError, "the record's keys already hold #{collisions.join(', ')}, which an expectation would " \
                         "not be able to name unambiguously"
      values = keys.dup
      %w[outcome rc ended].each { |f| values[f] = doc[f] if doc.key?(f) }
      faults = keys.select { |k, v| k.start_with?("faults.") && v.is_a?(Integer) }
      values["faults.raised"] = faults.select { |_, v| v.positive? }.keys
                                     .map { |k| k.delete_prefix("faults.") }.sort unless faults.empty?
      values
    end

    # rows -> [differences]. Raises CaseError where a row names something the
    # record does not carry, which is item 7's third kind of error.
    def self.judge(rows, values)
      missing = rows.reject { |r| values.key?(r.key) }.map(&:key)
      missing.empty? or
        raise CaseError, "the expectation names #{missing.length} key#{'s' if missing.length > 1} the record does " \
                         "not carry: #{missing.join(', ')}"
      rows.filter_map { |r| compare(r, values[r.key]) }
    end

    def self.compare(row, actual) # rubocop:disable Metrics/MethodLength
      case row.rule
      when "eq"
        case actual
        when Integer
          wanted = begin
            Integer(row.value, 10)
          rescue ArgumentError
            return Difference.new(row.key, "eq", row.value, actual, "(the record holds an integer)")
          end
          wanted == actual ? nil : Difference.new(row.key, "eq", wanted, actual, nil)
        when String
          # Byte for byte, and said so where the difference is invisible.
          return nil if row.value == actual
          detail = row.value.length == actual.length ? nil : "(lengths #{row.value.length} and #{actual.length})"
          Difference.new(row.key, "eq", row.value, actual, detail)
        else
          Difference.new(row.key, "eq", row.value, actual, "(the record holds #{actual.class})")
        end
      when "gt0"
        return Difference.new(row.key, "gt0", "an integer above zero", actual,
                              "(the record holds #{actual.class})") unless actual.is_a?(Integer)
        actual.positive? ? nil : Difference.new(row.key, "gt0", "an integer above zero", actual, nil)
      when "set"
        wanted = set_of(row.value)
        held = case actual
               when Array then actual.map(&:to_s).sort
               when String then set_of(actual)
               else return Difference.new(row.key, "set", wanted, actual, "(the record holds #{actual.class})")
               end
        return nil if wanted == held
        Difference.new(row.key, "set", wanted, held,
                       "missing=#{(wanted - held).inspect} unexpected=#{(held - wanted).inspect}")
      end
    end

    def self.set_of(text)
      return [] if text == "-"
      text.split(",").map(&:strip).reject(&:empty?).sort
    end
  end

  # How a child process ENDED, in the words a reader can act on: the status it
  # chose, or the signal that ended it instead. A case's run and an accounting
  # step's run are told apart from each other by everything except this, so it
  # is said once.
  def self.describe_status(status)
    return "status #{status.exitstatus}" if status.exitstatus
    return "the signal #{Signal.signame(status.termsig) || status.termsig}" if status.termsig
    status.to_s
  end

  # --------------------------------------------------------------- one case
  Result = Struct.new(:kase, :verdict, :reason, :differences, :record, :text, :outcome, :rc,
                      :wall_s, :peak_rss_kb, :rss_source, :runner_wall_s, :started_s, :ended_s,
                      :prerequisites, :expectations, :note, :designed_verdict, :designed_met,
                      keyword_init: true) do
    def report
      lines = [reason].compact
      lines.concat(differences.map(&:to_line)) if differences
      lines << "the run's output is at #{text}" if text
      lines.join("\n")
    end

    def to_h
      h = { "case_id" => kase["case_id"], "lane" => kase["lane"], "route" => kase["route"],
            "mode" => kase["mode"], "control" => kase["control"], "demo" => kase["demo"],
            "frames" => kase["frames"], "variant" => kase["variant"],
            "judged_against" => kase["judged_against"], "tiers" => kase.tiers_list,
            "verdict" => verdict, "reason" => reason,
            # NULL WHERE NOTHING WAS COMPARED, [] WHERE A COMPARISON FOUND
            # NOTHING. They are not the same statement and this field used to
            # make both of them as []: a skipped case, an errored one and an
            # accounting step that failed on its own terms all reported "no
            # differences", which on a FAILING row asserts that nothing
            # differed while the row is red because something did. That is the
            # row a reader is staring at while working out what went wrong, so
            # it is the most expensive place for a field to say the opposite of
            # what happened. Its failure is in `reason`.
            "differences" => differences&.map(&:to_h),
            "record" => record, "text" => text, "outcome" => outcome, "rc" => rc,
            "wall_s" => wall_s, "peak_rss_kb" => peak_rss_kb, "rss_source" => rss_source,
            "runner_wall_s" => runner_wall_s, "started_s" => started_s, "ended_s" => ended_s,
            "prerequisites" => prerequisites, "expectations" => expectations }
      h["note"] = note if note
      # On a mutation case `differences` is the DETECTION, not a list of
      # failures, and a report reading this document must not count it as one.
      # `detected` says which it is outright: true where the expectation caught
      # the deletion, false where nothing did, and null where the case errored
      # and answered neither.
      if kase.mutation
        h["mutation"] = kase.mutation
        h["detected"] = (verdict == "error" ? nil : !(differences || []).empty?)
      end
      # Same reason, for a case designed to end in something other than pass:
      # `verdict` alone would read as an ordinary pass, and a report must be
      # able to see that this one passed BY failing or BY erroring. `as_designed`
      # is null where the case skipped and reached no verdict to compare.
      if designed_verdict
        h["expected_verdict"] = designed_verdict
        h["as_designed"] = designed_met
      end
      h
    end
  end

  class CaseRunner
    attr_reader :dir

    def initialize(dir:, expectations:, require_all:, ruby:, started_at:)
      @dir = dir
      @expectations = expectations
      @require_all = require_all
      @ruby = ruby
      @started_at = started_at
    end

    # One case, then the declared-verdict reading of what it reached.
    def run(kase)
      designed(kase, attempt(kase))
    end

    def attempt(kase) # rubocop:disable Metrics/MethodLength
      began = now
      record = File.join(@dir, "records", "#{safe(kase['case_id'])}.json")
      text = File.join(@dir, "text", "#{safe(kase['case_id'])}.out")
      needed = kase.requires_list
      begin
        rows = @expectations[kase["judged_against"]]
        (rows && !rows.empty?) or
          raise CaseError, "no expectation rows judge #{kase['case_id']}: its judged_against names " \
                           "#{kase['judged_against'].inspect}"
        paths = resolve(needed)
        if paths.is_a?(String) # the name of the first missing prerequisite
          return finish(kase, began, needed,
                        verdict: @require_all ? "fail" : "skip",
                        reason: skip_reason(paths) + (@require_all ? ", and REQUIRE_ALL=1" : ""),
                        expectations: rows.length)
        end
        out = execute(kase, paths, record, text)
        doc = load_record(record, kase, out)
        values = Judge.exposed(doc)
        differences = Judge.judge(rows, values)
        finish(kase, began, needed, doc: doc, record: record, text: text, expectations: rows.length,
                                    differences: differences, note: out[:note],
                                    **verdict_of(kase, differences, rows.length))
      rescue CaseError => e
        finish(kase, began, needed, verdict: "error", reason: e.message,
                                    record: (record if File.exist?(record)), text: (text if File.exist?(text)),
                                    expectations: (rows ? rows.length : nil))
      end
    end

    private

    # THE ONE PLACE A DECLARED VERDICT IS READ, and the second of the header's
    # two inversions. A case DESIGNED_VERDICTS names is one whose job is to end
    # as something other than pass -- the shortened nominal that must fail the
    # expectation it is judged against, the killed run that must error -- so
    # what the case proves is that it reached that verdict and not another, and
    # that is what its pass and fail mean here. Without this the selftest tier
    # could never exit 0, and a reader would have to decide from prose which of
    # its failures were the designed ones.
    #
    # A SKIP IS NOT SUCH A VERDICT. It says a prerequisite was missing and the
    # case never ran, so there is nothing to compare: the skip stands, and the
    # document records the expected verdict with `as_designed` null.
    def designed(kase, result)
      want, why = DESIGNED_VERDICTS[kase["case_id"]]
      return result unless want

      result.designed_verdict = want
      return result if result.verdict == "skip"

      reached = result.verdict
      result.designed_met = reached == want
      was = result.reason ? " What it reached: #{result.reason}" : ""
      result.verdict = result.designed_met ? "pass" : "fail"
      result.reason =
        if result.designed_met
          "this case is DESIGNED to #{want}, and did. #{why}. Its #{want} is this case PASSING, and the " \
          "lines below are that evidence, not a failure.#{was}"
        else
          "this case is DESIGNED to #{want}, and ended as #{reached} instead, so the behaviour it exists to " \
          "prove was not shown. #{why}.#{was}"
        end
      result
    end

    # THE ONE PLACE THE MUTATION INVERSION LIVES. For an ordinary case a
    # differing expectation row is a failure. For a mutation case (item 8) the
    # expectation is the DETECTOR, and the case asks whether it fires: a
    # differing row means the deletion was seen, which is the case passing, and
    # an expectation that still holds over mutated source means nothing noticed,
    # which is the vacuous comparison the case exists to catch.
    def verdict_of(kase, differences, rows)
      unless kase.mutation
        return { verdict: differences.empty? ? "pass" : "fail",
                 reason: differences.empty? ? nil : "#{differences.length} of #{rows} expectation rows differ" }
      end
      spec = MUTATIONS.fetch(kase.mutation)
      if differences.empty?
        { verdict: "fail",
          reason: "the mutation deleted #{spec.what}, and all #{rows} expectation rows of " \
                  "#{kase['judged_against']} STILL HOLD: nothing detected the deletion, so that comparison is " \
                  "vacuous over this source. A mutation case fails by being undetected" }
      else
        { verdict: "pass",
          reason: "the mutation deleted #{spec.what}, and #{differences.length} of #{rows} expectation rows of " \
                  "#{kase['judged_against']} differ, which is the detection this case requires. The rows below " \
                  "are the evidence, not a failure" }
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def safe(id)
      id.to_s.gsub(%r{[/\\\s]}, "_")
    end

    def finish(kase, began, needed, doc: nil, **kw)
      ended = now
      Result.new(kase: kase, differences: nil, prerequisites: needed,
                 runner_wall_s: (ended - began).round(3),
                 started_s: (began - @started_at).round(3), ended_s: (ended - @started_at).round(3),
                 outcome: doc && doc["outcome"], rc: doc && doc["rc"],
                 wall_s: doc && doc.dig("time", "wall_s"),
                 peak_rss_kb: doc && doc.dig("time", "peak_rss_kb"),
                 rss_source: doc && doc.dig("time", "rss_source"),
                 **kw)
    end

    def skip_reason(name)
      spec = PREREQUISITES.fetch(name)
      "the prerequisite #{name} is missing: #{spec[:what]}, named by #{spec[:env]}"
    end

    # [name => path] or the name of the FIRST missing one, so a skip says which
    # prerequisite is absent rather than that something was.
    def resolve(names)
      paths = {}
      names.each do |name|
        spec = PREREQUISITES[name] or
          raise CaseError, "the case requires #{name.inspect}, which this runner does not know how to find"
        path = ENV[spec[:env]].to_s.empty? ? spec[:default].call : ENV[spec[:env]]
        return name if path.nil? || path.empty?
        return name unless spec[:kind] == :dir ? File.directory?(path) : File.exist?(path)
        paths[name] = path
      end
      paths
    end

    # ONE case is ONE process. Returns { status:, killed:, note: }.
    def execute(kase, paths, record, text)
      env, note, root = environment(kase, paths, record)
      # `root` is the worktree for every case but a mutation's, which runs the
      # copy's own `source-port.rb` so that the copy's `__dir__` makes the
      # mutated tree its root.
      argv = [@ruby, File.join(root, "tests/doom-core/source-port.rb"),
              paths.fetch("wad"), kase["mode"], kase.frames_i.to_s, kase["control"]]
      # A killed run must leave NO document: source-port.rb empties the path
      # itself, but not before it starts, so an earlier run's record is cleared
      # here rather than read as this one's result.
      begin
        File.delete(record) if File.exist?(record)
      rescue SystemCallError => e
        raise CaseError, "an earlier record at #{record} could not be cleared: #{e.class}: #{e.message}"
      end
      pid = Process.spawn(env, *argv, out: text, err: [:child, :out], in: File::NULL)
      kase["variant"] == "kill" ? wait_and_kill(pid, note) : { status: wait(pid), killed: false, note: note }
    rescue Errno::ENOENT => e
      raise CaseError, "the case could not be started: #{e.class}: #{e.message}"
    end

    def wait(pid)
      Process.waitpid2(pid)[1]
    end

    def wait_and_kill(pid, note)
      deadline = now + KILL_AFTER_S
      status = nil
      while now < deadline
        got = Process.waitpid2(pid, Process::WNOHANG)
        if got
          status = got[1]
          break
        end
        sleep 0.02
      end
      if status
        raise CaseError, "the kill variant's run ended on its own within #{KILL_AFTER_S}s, so nothing was " \
                         "interrupted and the case proves nothing; shorten HARNESS_KILL_AFTER_S or lengthen the case"
      end
      Process.kill("KILL", pid)
      { status: wait(pid), killed: true, note: [note, "killed after #{KILL_AFTER_S}s"].compact.join("; ") }
    end

    # The route's variables, the variant's, and nothing inherited: a stray
    # SOURCE_PORT_NATIVE in the caller's shell would otherwise change the route
    # under a case that never asked for it. The furniture switch, a skipped
    # boundary copy, a recording and another leaves.rb change the run as much, so they are
    # cleared too: a stray SOURCE_PORT_GOLDEN would run a comparison no case
    # asked for.
    def environment(kase, paths, record)
      env = { "SOURCE_PORT_NATIVE" => nil, "SOURCE_PORT_SESSION" => nil, "SOURCE_PORT_ADAPTER" => nil,
              "SOURCE_PORT_FIELDS" => nil, "SOURCE_PORT_ADAPTER_UNTRACKED" => nil,
              "SOURCE_PORT_FURNITURE" => nil, "SOURCE_PORT_COPY_SKIP" => nil, "SOURCE_PORT_GOLDEN" => nil,
              "SOURCE_PORT_LEAVES" => nil,
              "SOURCE_PORT_DEMO" => kase["demo"],
              "SOURCE_PORT_RECORD" => record }
      case kase["route"]
      when "ruby" then nil
      when "compiled"
        env["SOURCE_PORT_NATIVE"] = paths.fetch("source-lib")
      when "session"
        env["SOURCE_PORT_NATIVE"] = paths.fetch("source-lib")
        env["SOURCE_PORT_SESSION"] = paths.fetch("session-dir")
        env["SOURCE_PORT_FIELDS"] = FIELDS
      when "adapter"
        env["SOURCE_PORT_NATIVE"] = paths.fetch("adapter-lib")
        env["SOURCE_PORT_SESSION"] = paths.fetch("session-dir")
        env["SOURCE_PORT_ADAPTER"] = paths.fetch("adapter-lib")
        env["SOURCE_PORT_FIELDS"] = FIELDS
      else
        raise CaseError, "the case names the route #{kase['route'].inspect}, which this runner does not know"
      end
      note, root = variant(kase, env)
      [env, note, root || ROOT]
    end

    # A variant that the route would ignore is refused: a case whose one
    # changed thing changes nothing is vacuous, and a vacuous case must not
    # pass. Returns [note, tree-root-or-nil].
    def variant(kase, env)
      return mutate(kase) if kase.mutation

      case kase["variant"]
      when "-", "", nil then [nil, nil]
      when "kill" then [nil, nil]
      when "fields=wrongslot"
        %w[session adapter].include?(kase["route"]) or
          raise CaseError, "the variant fields=wrongslot names a field map, which only the session and adapter " \
                           "routes read; the #{kase['route']} route would ignore it"
        path, changed = wrongslot(kase)
        env["SOURCE_PORT_FIELDS"] = path
        ["fields=wrongslot changed #{changed} rows of #{File.basename(FIELDS)}", nil]
      when "untracked=result"
        kase["route"] == "adapter" or
          raise CaseError, "the variant untracked=result names an adapter allocation, which only the adapter " \
                           "route makes; the #{kase['route']} route would ignore it"
        env["SOURCE_PORT_ADAPTER_UNTRACKED"] = "result"
        ["untracked=result", nil]
      else
        raise CaseError, "the case names the variant #{kase['variant'].inspect}, which this runner does not know"
      end
    end

    # A MUTATION'S PRIVATE COPY (item 8). Copies the subtrees `source-port.rb`
    # reads into `trees/<case>/` under the run directory, applies the deletion
    # THERE, and answers [note, that root]. The worktree is never opened for
    # writing: the file that is edited is the copy's, and a run of the copy
    # takes its whole root from the copy's own `source-port.rb`.
    #
    # An edit that matched nothing RAISES, which the caller turns into `error`:
    # the run that would have followed is the unmutated nominal under a
    # mutation's name, and it would then pass -- inverted, fail -- for a reason
    # having nothing to do with what the case claims to test.
    def mutate(kase)
      spec = MUTATIONS[kase.mutation] or
        raise CaseError, "the case names the mutation #{kase.mutation.inspect}, which this runner does not know; " \
                         "they are #{MUTATIONS.keys.join(', ')}"
      kase["route"] == "ruby" or
        raise CaseError, "the variant #{kase['variant']} deletes Ruby source under examples/doom/core/src, which " \
                         "only the ruby route interprets; the #{kase['route']} route loads a prebuilt object that " \
                         "this runner does not rebuild, so it would ignore the deletion"
      root = File.join(@dir, "trees", safe(kase["case_id"]))
      FileUtils.rm_rf(root)
      TREE_SUBDIRS.each do |sub|
        FileUtils.mkdir_p(File.dirname(File.join(root, sub)))
        FileUtils.cp_r(File.join(ROOT, sub), File.join(root, sub))
      end
      target = File.join(root, spec.file)
      File.exist?(target) or
        raise CaseError, "the mutation names #{spec.file}, which the copy at #{root} does not hold"
      before = File.read(target)
      cut = spec.cut
      hits = before.scan(cut).length
      hits == 1 or
        raise CaseError, "the mutation #{kase.mutation} matched #{hits} times in #{spec.file}, not once, so it " \
                         "deleted #{hits.zero? ? 'nothing' : 'more than it names'}; it means to delete " \
                         "#{spec.what}. A mutation that changed no byte proves nothing: it is an error, never a pass"
      after = before.sub(cut, "")
      after == before and
        raise CaseError, "the mutation #{kase.mutation} left #{spec.file} byte-identical"
      File.write(target, after)
      bytes = before.length - after.length
      ["#{kase['variant']} deleted #{spec.what} from #{spec.file} (#{bytes} bytes, #{spec.lines.length} lines) " \
       "in #{root}", root]
    end

    # The wrong-slot field map, derived in the run directory from the TRACKED
    # fixture: the column base is given the neighbouring render slot, which the
    # static check still accepts and only the per-call slot check can see.
    def wrongslot(kase)
      File.exist?(FIELDS) or raise CaseError, "no field map at #{FIELDS}"
      tab = "\t"
      changed = 0
      out = File.readlines(FIELDS, chomp: true).map do |line|
        was = line
        line = line.sub(/\A(direct-column#{tab}col#{tab}i_base#{tab})renderer_dc_srcbase(#{tab}in)\z/,
                        '\1renderer_dc_colormap\2')
        line = line.sub(/\A(produce-column#{tab}[a-z]*#{tab}i_base#{tab})renderer_dc_srcbase(#{tab}inout)\z/,
                        '\1renderer_dc_colormap\2')
        changed += 1 unless line == was
        line
      end
      changed.positive? or
        raise CaseError, "the wrong-slot field map is identical to #{FIELDS}, so the control would be vacuous"
      path = File.join(@dir, "fixtures", "#{safe(kase['case_id'])}.fields-wrongslot.tsv")
      File.write(path, out.join("\n") + "\n")
      [path, changed]
    end

    def load_record(record, kase, out)
      unless File.exist?(record)
        raise CaseError, "no result record at #{record}#{" (#{out[:note]})" if out[:note]}: " \
                         "the run ended as #{Harness.describe_status(out[:status])} and wrote nothing"
      end
      doc = begin
        JSON.parse(File.read(record))
      rescue JSON::ParserError => e
        raise CaseError, "the result record at #{record} is not JSON: #{e.message}"
      end
      doc.is_a?(Hash) or raise CaseError, "the result record at #{record} is not a document"
      %w[completed refused].include?(doc["outcome"]) or
        raise CaseError, "the run ended as #{doc['outcome'].inspect}#{", #{doc['ended']}" if doc['ended']}, " \
                         "which is neither completed nor refused"
      identify(doc, kase)
      doc
    end

    # The record must be THIS case's run. `mode`, `control` and the requested
    # count are only parsed on a run that got that far, so a refusal is held to
    # the route alone -- which the environment settles and always records.
    def identify(doc, kase)
      doc["route"] == kase["route"] or
        raise CaseError, "the record says the route was #{doc['route'].inspect}, and the case declares " \
                         "#{kase['route'].inspect}"
      return unless doc["outcome"] == "completed"
      { "mode" => kase["mode"], "control" => kase["control"] }.each do |field, want|
        doc[field] == want or
          raise CaseError, "the record says #{field} was #{doc[field].inspect}, and the case declares #{want.inspect}"
      end
      doc["requested_tics"] == kase.frames_i or
        raise CaseError, "the record was asked for #{doc['requested_tics'].inspect} tics, and the case declares " \
                         "#{kase.frames_i}"
    end
  end

  # ------------------------------------------------------- the accounting steps
  # THE ACCOUNTING STEPS of the selftest tier (0009's clarification "the
  # accounting runs inside a tier"). `pins.rb` extracts the frozen tick.sh pins
  # and `cases.rb` checks the case matrix against them; a checker no gate reaches
  # is a document and not a check, so the tier runs them. They join it as STEPS
  # and not as cases: they run no port, no expectation judges them, and nothing
  # in cases/frame.tsv selects them by column, so the matrix's tier counts are
  # what they were. What they do leave is a Result row carrying one of the four
  # verdicts, which is the whole point of doing it here rather than in a script
  # beside the runner: the totals, the JUnit document and the no-fail-and-no-
  # error gate then count the accounting with no new vocabulary to teach them.
  #
  # THEY ARE TWO STEPS BECAUSE THEY SIT ON OPPOSITE SIDES OF ONE LINE, and
  # `harness/expect.rb` is where that line is drawn: GENERATING AN EXPECTATION
  # NEEDS A GIT CHECKOUT; RUNNING ONE DOES NOT. Looking a commit up needs the
  # repository's history; judging a tracked file against a tracked file needs
  # nothing but the files.
  #
  #   selftest.pins-tracked      THE RUNNING SIDE. It reads the tracked
  #                              expect/pins.tsv, holds its header to the frozen
  #                              identity above, and runs cases.rb over it. No
  #                              git, no history, no revision: an unpacked
  #                              archive of the worktree runs this step exactly
  #                              as a checkout does, which is the promise this
  #                              file's header makes of the runner as a whole.
  #   selftest.pins-regenerate   THE GENERATING SIDE. It re-extracts the pins at
  #                              the frozen revision and requires the result to
  #                              be byte-identical to the tracked file, which is
  #                              what makes that file's header more than a claim
  #                              about itself. Re-extracting reads the revision,
  #                              so this step, alone in this file, needs the
  #                              history.
  #
  # So exactly ONE of the two carries a prerequisite, and it is the generating
  # one. A reader who finds a git call in a runner whose header promises none is
  # reading `regenerate` below; `tracked`, a few methods above it, is the step
  # every ordinary verification line runs and it calls nothing of the sort.
  #
  # THE PREREQUISITE IS THE REVISION RESOLVING, NOT GIT BEING INSTALLED. A
  # shallow clone has git on PATH and does not have the frozen commit, so a check
  # for the program would be satisfied in exactly the case where the step cannot
  # run, and the step would then fail as though the pins were wrong. It therefore
  # asks the question it actually depends on -- `git rev-parse --verify
  # REVISION^{commit}` -- and skips on the answer. The skip NAMES what is missing
  # and what is lost with it: with no frozen revision to read, nothing here has
  # shown the tracked pins to be what tick.sh holds there. Under `REQUIRE_ALL=1`
  # that skip becomes a fail, exactly as a case's missing prerequisite does.
  module Accounting
    TRACKED = "selftest.pins-tracked"
    REGENERATE = "selftest.pins-regenerate"
    STEPS = [TRACKED, REGENERATE].freeze

    # cases.rb's tally line, and the whole of what is read out of its output: it
    # prints each problem one per line above this, and this counts them. A run
    # that printed no such line is a failure and never a pass -- a step that
    # accepts the absence of an answer as an answer checks nothing.
    TALLY = /^cases: (\d+) rows, (\d+) pins, (\d+) problems$/.freeze

    # The steps as Cases, so one Result shape serves both them and the matrix's
    # rows. No file declares these, so every column that does not apply to a step
    # holds `-`, which is the matrix's own spelling for a cell with no value.
    def self.cases
      STEPS.map do |id|
        Case.new(*COLUMNS.map do |column|
          case column
          when "case_id" then id
          when "tiers" then SELFTEST_TIER
          else "-"
          end
        end)
      end
    end

    class Runner
      def initialize(dir:, require_all:, ruby:, started_at:)
        @dir = dir
        @require_all = require_all
        @ruby = ruby
        @started_at = started_at
      end

      # ONE step, as a Result of the shape a case leaves behind, so that nothing
      # downstream has to know this row was not a case.
      def run(kase)
        began = now
        step = case kase["case_id"]
               when TRACKED then tracked
               when REGENERATE then regenerate
               else { verdict: "error",
                      reason: "this runner knows no accounting step called #{kase['case_id'].inspect}; " \
                              "they are #{STEPS.join(', ')}" }
               end
        ended = now
        Result.new(kase: kase, differences: nil, prerequisites: step.delete(:prerequisites) || [],
                   runner_wall_s: (ended - began).round(3),
                   started_s: (began - @started_at).round(3), ended_s: (ended - @started_at).round(3),
                   **step)
      end

      private

      # THE RUNNING SIDE. Needs no git and no revision; see THE ACCOUNTING STEPS
      # above.
      def tracked
        File.exist?(PINS) or
          return { verdict: "fail",
                   reason: "no tracked pins at #{PINS}: the matrix's provenance column is accounted for against " \
                           "that file and against nothing else, so without it the accounting asserts nothing. " \
                           "Write it with `ruby #{PINS_RB} --out #{PINS}`" }
        problem = header_problem
        return { verdict: "fail", reason: problem } if problem

        accounted
      end

      # The tracked file's own header against the frozen identity this runner
      # holds. Both the expected value and the one found are named, so the
      # message says WHICH file is in the tree without anyone opening it.
      def header_problem # rubocop:disable Metrics/MethodLength
        lines = File.readlines(PINS, chomp: true)
        revision = header_fields(lines, "revision")
        blob = header_fields(lines, "blob")
        return "the tracked pins at #{PINS} carry no `# revision` header line, so nothing in the file says which " \
               "revision they were extracted from; they must name #{PINS_REVISION} #{PINS_COMMIT}" if revision.nil?
        return "the tracked pins at #{PINS} carry no `# blob` header line, so nothing in the file says which " \
               "#{PINS_TICK} they were extracted from; they must name #{PINS_TICK_BLOB}" if blob.nil?
        if revision.first(2) != [PINS_REVISION, PINS_COMMIT]
          return "the tracked pins at #{PINS} name the revision #{revision.first(2).join(' ')}, and these " \
                 "expectations were taken at #{PINS_REVISION} #{PINS_COMMIT}: pins extracted anywhere else do " \
                 "not stand behind them"
        end
        return nil if blob.first == PINS_TICK_BLOB

        "the tracked pins at #{PINS} name the #{PINS_TICK} blob #{blob.first}, and these expectations were taken " \
        "from the blob #{PINS_TICK_BLOB}: the revision says which history was read, and the blob says which file"
      end

      # `# NAME\tvalue...` -> the values, or nil where the file has no such line.
      def header_fields(lines, name)
        line = lines.find { |l| l.start_with?("# #{name}\t") } or return nil
        line.split("\t").drop(1)
      end

      # Every pin claimed or retired by exactly one row, which is cases.rb's
      # whole rule. Both its exit status and its own count are read, and they
      # must agree: a checker that exits 0 while reporting problems, or the other
      # way about, has told two stories and neither is evidence.
      def accounted
        out, status = capture(@ruby, CASES_RB, "--pins", PINS)
        status or
          return { verdict: "fail", reason: "#{CASES_RB} could not be started: #{out}" }
        tally = TALLY.match(out) or
          return { verdict: "fail",
                   reason: "#{CASES_RB} printed no `cases: N rows, M pins, K problems` line, so nothing says " \
                           "whether the matrix and the pins account for each other; it ended as " \
                           "#{Harness.describe_status(status)}. Its output follows.\n#{out}" }
        rows, pins, problems = tally.captures
        unless status.success? && problems == "0"
          return { verdict: "fail",
                   reason: "#{CASES_RB} reports #{problems} problem#{'s' unless problems == '1'} over #{rows} " \
                           "matrix rows and #{pins} pins, and ended as #{Harness.describe_status(status)}; a pin " \
                           "claimed by no row, or a row accounting for a pin that is not there, is the migration " \
                           "losing a check. Its output follows.\n#{out}" }
        end
        { verdict: "pass", note: "#{CASES_RB}: #{rows} rows, #{pins} pins, 0 problems against #{PINS}" }
      end

      # THE GENERATING SIDE, and the one step in this file that reads the
      # repository's history; see THE ACCOUNTING STEPS above for why the line
      # falls here and why the prerequisite is the revision and not the program.
      def regenerate
        answer, status = capture("git", "rev-parse", "--verify", "#{PINS_REVISION}^{commit}")
        return unresolved(answer) unless status&.success?

        File.exist?(PINS) or
          return { verdict: "fail",
                   reason: "no tracked pins at #{PINS} for the extraction at #{PINS_REVISION} to be compared " \
                           "against, so the regenerated file would be judged by nothing. Write it with " \
                           "`ruby #{PINS_RB} --out #{PINS}`" }
        made = File.join(@dir, "fixtures", "pins-regenerated.tsv")
        out, status = capture(@ruby, PINS_RB, "--revision", PINS_REVISION, "--out", made)
        (status && status.success?) or
          return { verdict: "fail",
                   reason: "#{PINS_RB} could not extract the pins at #{PINS_REVISION}: it ended as " \
                           "#{status ? Harness.describe_status(status) : out}. Its output follows.\n#{out}" }
        want = File.binread(PINS)
        got = File.binread(made)
        return { verdict: "pass",
                 note: "#{PINS_RB} at #{PINS_REVISION} regenerates #{PINS} byte for byte " \
                       "(#{want.bytesize} bytes)" } if want == got

        { verdict: "fail", reason: difference(want, got, made) }
      end

      # The skip, which names the revision that is missing AND what nobody knows
      # without it. `REQUIRE_ALL=1` turns it into a fail with the reason it would
      # have skipped with, which is the case path's behaviour and is written the
      # same way here so the two read alike in one report.
      #
      # AND UNDER `REQUIRE_ALL=1` IT SAYS WHAT NOT TO DO, because the fix that
      # makes this message go away is unsetting the variable, and that is the
      # one fix that must not be taken: it turns a check that did not run back
      # into a silent skip and gives up what the gate is for. An operator meets
      # this while looking for a way to a green run, which is exactly when the
      # cheapest wrong move is the obvious one, so the sentence is in the
      # message rather than in a document the operator is not reading.
      def unresolved(answer)
        said = answer.to_s.lines.first.to_s.strip
        reason = "the frozen revision #{PINS_REVISION} does not resolve in the checkout at #{ROOT}, so " \
                 "`git rev-parse --verify #{PINS_REVISION}^{commit}` answered #{said.inspect} and the pins " \
                 "cannot be regenerated: nothing here has read #{PINS_TICK} as it stood at that revision, so the " \
                 "tracked #{PINS} is not shown to be current against it. A shallow clone is the ordinary way to " \
                 "be here, and fetching that revision is the way out"
        warning = ", and REQUIRE_ALL=1, which is why this is a failure and not a skip. Do not unset " \
                  "REQUIRE_ALL to get a green run: that turns a check that did not run back into a silent " \
                  "skip and gives up what the gate is for. Fetch the revision instead"
        { verdict: @require_all ? "fail" : "skip",
          reason: reason + (@require_all ? warning : ""),
          prerequisites: ["#{PINS_TICK}@#{PINS_REVISION}"] }
      end

      # WHERE the two differ, not merely that they do. A pin is one very long
      # line -- the whole expected report -- so the first differing line is named
      # and both sides are cut to their opening characters; the regenerated file
      # stays in the run directory for whoever wants the rest of it.
      EXCERPT = 120

      def difference(want, got, made)
        theirs = want.lines
        ours = got.lines
        n = (0...[theirs.length, ours.length].max).find { |i| theirs[i] != ours[i] }
        "the pins regenerated from #{PINS_REVISION} into #{made} are not byte-identical to the tracked #{PINS}, " \
        "so the tracked file is not what #{PINS_RB} extracts at that revision and the expectations rest on a " \
        "file nobody can reproduce. The first of #{[theirs.length, ours.length].max} lines to differ is " \
        "#{n + 1}:\n  tracked     #{excerpt(theirs[n])}\n  regenerated #{excerpt(ours[n])}"
      end

      def excerpt(line)
        return "(the file has no line there)" if line.nil?
        text = line.chomp
        text.length > EXCERPT ? "#{text[0, EXCERPT].inspect} (#{text.length} characters)" : text.inspect
      end

      # A program this step runs, from the checkout, with its output and its
      # errors joined: both checkers name their own paths relative to the
      # checkout, and a reader needs what they printed on either stream. A
      # program that is not there answers nil rather than raising -- `git`
      # absent and `git` unable to resolve the revision are the same answer to
      # the same question, which is whether this step can run at all.
      def capture(*argv)
        Open3.capture2e(*argv, chdir: ROOT)
      rescue Errno::ENOENT => e
        ["#{e.class}: #{e.message}", nil]
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  # ------------------------------------------------------------- the reports
  # Both drivers write these, and every number in a commit report comes from
  # them (0009 item 10).
  module Reports
    def self.summary(dir:, results:, meta:)
      counts = Hash.new(0)
      results.each { |r| counts[r.verdict] += 1 }
      doc = {
        "harness" => 1,
        "run" => meta[:run],
        "selection" => meta[:selection],
        "env" => meta[:env],
        "totals" => { "cases" => results.length, "pass" => counts["pass"], "fail" => counts["fail"],
                      "error" => counts["error"], "skip" => counts["skip"] },
        "cases" => results.sort_by { |r| r.kase["case_id"] }.map(&:to_h)
      }
      File.write(File.join(dir, "summary.json"), JSON.pretty_generate(doc) + "\n")
      doc
    end

    def self.junit(dir:, doc:)
      t = doc["totals"]
      xml = +%(<?xml version="1.0" encoding="UTF-8"?>\n)
      xml << format(%(<testsuites tests="%d" failures="%d" errors="%d" skipped="%d" time="%s">\n),
                    t["cases"], t["fail"], t["error"], t["skip"], doc["run"]["wall_s"])
      xml << format(%(  <testsuite name="doom-core.harness" tests="%d" failures="%d" errors="%d" skipped="%d" ) +
                    %(time="%s" timestamp="%s">\n),
                    t["cases"], t["fail"], t["error"], t["skip"], doc["run"]["wall_s"], doc["run"]["started"])
      # THE CLASSNAME IS `lane.route`, AND FOR THE ACCOUNTING STEPS IT COMES OUT
      # `-.-` ON PURPOSE. Those rows are not cases of the matrix: they have no
      # lane and no route, so both fields carry the `-` this lane already uses
      # for a column that does not apply, and the classname is that convention
      # applied honestly rather than a placeholder somebody forgot.
      #
      # NO OTHER VALUE WAS INVENTED, and the reason is worth more than the
      # value: a second rule for building a classname would be new vocabulary
      # in the report, chosen to satisfy a consumer nobody has met. There is no
      # CI here and no reader of this XML has been demonstrated, so there is no
      # input that makes `-.-` fail -- and a value picked to please an imagined
      # consumer is a check that could not have failed, in formatting. If a CI
      # ever needs these rows grouped, that is the moment the requirement
      # exists and the moment to name it, with the consumer in hand to say what
      # it needs, as a report-format decision taken deliberately rather than a
      # patch applied to one row.
      doc["cases"].each do |c|
        xml << format(%(    <testcase classname="%s" name="%s" time="%s">),
                      esc("#{c['lane']}.#{c['route']}"), esc(c["case_id"]), c["runner_wall_s"])
        body = ([c["reason"]] + (c["differences"] || []).map do |d|
          format("%s rule=%s expected=%s record=%s%s", d["key"], d["rule"], d["expected"].inspect,
                 d["record"].inspect, d["detail"] ? " #{d['detail']}" : "")
        end).compact.join("\n")
        case c["verdict"]
        when "fail" then xml << %(\n      <failure message="#{esc(c['reason'].to_s)}">#{esc(body)}</failure>\n    )
        when "error" then xml << %(\n      <error message="#{esc(c['reason'].to_s)}">#{esc(body)}</error>\n    )
        when "skip" then xml << %(\n      <skipped message="#{esc(c['reason'].to_s)}"/>\n    )
        end
        xml << "</testcase>\n"
      end
      xml << "  </testsuite>\n</testsuites>\n"
      File.write(File.join(dir, "junit.xml"), xml)
    end

    def self.esc(s)
      s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
    end
  end

  # ---------------------------------------------------------------- the cap
  # The concurrency cap, held here rather than by the scheduler, so it means
  # the same under either driver and under either minitest line.
  class Gate
    def initialize(size)
      @slots = Thread::SizedQueue.new(size)
    end

    def hold
      @slots.push(true)
      begin
        yield
      ensure
        @slots.pop
      end
    end
  end

  # --------------------------------------------------------------- the CLI
  module CLI
    FLAGS = { "--case" => "case_id", "--case-id" => "case_id", "--tier" => "tiers", "--requires" => "requires",
              "--judged-against" => "judged_against" }.freeze

    def self.parse(argv) # rubocop:disable Metrics/MethodLength
      o = { filters: Hash.new { |h, k| h[k] = [] }, jobs: 1, list: false, driver: "minitest",
            matrix: File.join(ROOT, "tests/doom-core/cases/frame.tsv"),
            expect: File.join(ROOT, "tests/doom-core/expect/frame.tsv") }
      args = argv.dup
      until args.empty?
        flag = args.shift
        column = FLAGS[flag] || (flag.start_with?("--") && COLUMNS.include?(flag[2..].tr("-", "_")) &&
                                 flag[2..].tr("-", "_"))
        if column
          o[:filters][column].concat(value!(flag, args).split(","))
          next
        end
        case flag
        when "--jobs" then o[:jobs] = count(flag, value!(flag, args))
        when "--matrix" then o[:matrix] = value!(flag, args)
        when "--expect" then o[:expect] = value!(flag, args)
        when "--driver" then o[:driver] = value!(flag, args)
        when "--list" then o[:list] = true
        when "-h", "--help" then o[:help] = true
        else raise Refusal, "unknown option #{flag.inspect}; run with --help"
        end
      end
      o[:jobs] >= 1 or raise Refusal, "--jobs must be at least 1, and #{o[:jobs]} is not"
      %w[minitest plain].include?(o[:driver]) or
        raise Refusal, "--driver names #{o[:driver].inspect}; it takes minitest or plain"
      o
    end

    # A bad option is a Refusal -- exit 2 with a sentence -- and never a
    # backtrace out of the parser: the caller mistyped a flag, which is not a
    # harness fault to debug.
    def self.value!(flag, args)
      v = args.shift
      (v && !v.empty?) or raise Refusal, "#{flag} needs a value"
      v.start_with?("--") and raise Refusal, "#{flag} needs a value, and #{v.inspect} is the next option"
      v
    end

    def self.count(flag, text)
      Integer(text, 10)
    rescue ArgumentError
      raise Refusal, "#{flag} takes a whole number, and #{text.inspect} is not one"
    end

    def self.usage
      File.readlines(__FILE__).drop(1).take_while { |l| l.start_with?("#") }.map { |l| l.sub(/\A# ?/, "") }.join
    end
  end

  # ------------------------------------------------------------ the schedule
  class Run
    attr_reader :cases, :accounting, :options, :results

    # A path with every symlink on it resolved. `File.realpath` alone is not
    # enough: it needs the whole path to exist, and a run directory usually does
    # not exist yet. So what does not resolve is taken apart --
    #
    #   a DANGLING symlink   is read and its target resolved in its place. This
    #                        is the case a nearest-existing-ancestor walk misses
    #                        and the one that matters most: a link created ahead
    #                        of the run, whose target is inside the checkout.
    #   anything else        has its parent resolved and its own name joined on.
    #
    # -- until either the realpath succeeds or the filesystem root is reached.
    # The depth cap ends a symlink loop, which the kernel would refuse anyway;
    # there is nothing further to learn from one, so the path stands as written.
    RESOLVE_DEPTH = 32

    def self.resolve(path, depth = 0)
      absolute = File.expand_path(path)
      begin
        return File.realpath(absolute)
      rescue SystemCallError
        return absolute if depth >= RESOLVE_DEPTH
      end
      if File.symlink?(absolute)
        target = File.readlink(absolute)
        return resolve(target.start_with?(File::SEPARATOR) ? target : File.join(File.dirname(absolute), target),
                       depth + 1)
      end
      parent = File.dirname(absolute)
      return absolute if parent == absolute
      File.join(resolve(parent, depth + 1), File.basename(absolute))
    end

    def initialize(options)
      @options = options
      # `--list` selects and prints; it runs nothing and writes nothing, so it
      # needs no run directory. Every other use does, and says so here rather
      # than after the first case has already started.
      unless options[:list]
        @dir = ENV["HARNESS_RUN"].to_s
        @dir.empty? and raise Refusal, "HARNESS_RUN must name a per-run directory (0009 item 7)"
        @dir = File.expand_path(@dir)
        # A run directory holds records, copied trees and built artifacts, none
        # of which belongs in the checkout: it would show up as untracked work,
        # and a mutation case's copy of the tree would sit inside the tree it
        # copied. The 0009 clarification puts these locations outside every
        # worktree.
        #
        # THE COMPARISON IS ON RESOLVED PATHS, NOT ON THE TEXT. A symlink walks
        # straight through a textual comparison in either direction: a link
        # outside the worktree whose target is inside it, and a checkout reached
        # through a link, whose ROOT -- taken from this file's own `__dir__` --
        # is then spelled differently from the same directory's real path. Both
        # were measured to create `records/`, `text/`, `fixtures/` and `trees/`
        # inside the worktree.
        inside = Run.resolve(@dir)
        root = Run.resolve(ROOT)
        if inside == root || inside.start_with?("#{root}#{File::SEPARATOR}")
          raise Refusal, "HARNESS_RUN is #{@dir}#{", which resolves to #{inside}" if inside != @dir}, and " \
                         "that is inside the checkout at #{ROOT}#{", which resolves to #{root}" if root != ROOT}; " \
                         "a run directory holds records, built artifacts and copies of the tree, " \
                         "and belongs outside every worktree. The two are compared as resolved paths, so a " \
                         "symlink on either side does not get around it"
        end
        %w[records text fixtures trees].each { |d| FileUtils.mkdir_p(File.join(@dir, d)) }
      end
      cases = Matrix.read(options[:matrix])
      @cases = Matrix.select(cases, options[:filters])
      if @cases.empty?
        hidden = cases.count { |c| c.retired? || c.selftest? }
        raise Refusal, "no case in #{options[:matrix]} matches #{describe_filters}; a selection that matches " \
                       "nothing is an error, not a pass. #{hidden} of its #{cases.length} rows are tiered " \
                       "#{RETIRED_TIER} or #{SELFTEST_TIER} and no selection reaches them: a retirement is never " \
                       "run, and a selftest row needs --tier #{SELFTEST_TIER}"
      end
      # The accounting steps run where `--tier selftest` asked for the harness's
      # own tests and nowhere else: they judge the harness's bookkeeping, not a
      # run of the port, so a lane selection that picked them up would report the
      # harness's own accounting as a lane result. They are not matrix rows, so
      # this reads the SELECTION and not the matrix.
      @accounting = options[:filters].fetch("tiers", []).include?(SELFTEST_TIER) ? Accounting.cases : []
      @expect_path = options[:expect]
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @started = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      @gate = Gate.new(options[:jobs])
      # Built here and not on first use: both drivers reach it from a thread,
      # and a memoized build is a race rather than a read.
      @accounting_runner = Accounting::Runner.new(dir: @dir, require_all: ENV["REQUIRE_ALL"] == "1",
                                                  ruby: ENV["RUBY"].to_s.empty? ? RbConfig.ruby : ENV["RUBY"],
                                                  started_at: @started_at)
      @results = []
      @lock = Mutex.new
    end

    # Read when the cases are about to run, so that selecting and listing work
    # before the expectations of the lane exist.
    def runner
      @runner ||= CaseRunner.new(dir: @dir, expectations: Expectations.read(@expect_path),
                                 require_all: ENV["REQUIRE_ALL"] == "1",
                                 ruby: ENV["RUBY"].to_s.empty? ? RbConfig.ruby : ENV["RUBY"],
                                 started_at: @started_at)
    end

    def describe_filters
      return "every row (no selection was given)" if @options[:filters].empty?
      @options[:filters].map { |c, v| "#{c}=#{v.join(',')}" }.join(" ")
    end

    def run_case(kase)
      result = @gate.hold { @runner.run(kase) } # `runner` is forced before any thread starts
      @lock.synchronize { @results << result }
      result
    end

    # ONE accounting step, into the same @results the cases land in, so that
    # every report and every gate reads it without being told about it.
    def run_accounting(kase)
      result = @gate.hold { @accounting_runner.run(kase) }
      @lock.synchronize { @results << result }
      result
    end

    # Plain Ruby, no minitest: the same cases, the same cap, the same reports.
    #
    # THE STATUS IS DECIDED ONCE, AFTER EVERY RESULT EXISTS, and nothing between
    # here and the last line short-circuits it. Every thread is joined, then
    # every row is printed, and only then does the gate read the verdicts: one
    # red row can never end the run before a later row has been reported, and no
    # row is reported behind an exit that has already happened. THE ACCOUNTING
    # STEP'S SKIP PATH RELIES ON THIS: under REQUIRE_ALL=1 that skip becomes a
    # fail, and the state where an operator most needs to read it is the state
    # where something else failed too. The invariant currently holds because of
    # where these lines sit and nothing else, which is why it is written down --
    # an early exit added above them would suppress exactly the diagnostics that
    # a red run needs, and every row that did print would still look correct.
    def drive_plain
      threads = @cases.map { |k| Thread.new { run_case(k) } }
      threads.concat(@accounting.map { |k| Thread.new { run_accounting(k) } })
      threads.each(&:join)
      @results.sort_by { |r| r.kase["case_id"] }.each do |r|
        puts "#{r.verdict.upcase} #{r.kase['case_id']}"
        # A mutation case that passed carries the detection as its differing
        # rows, and a case with a declared verdict carries in its reason WHICH
        # way round its pass is to be read. Both are the point of the case, so
        # both print; only an ordinary silent pass is skipped.
        next if r.verdict == "pass" && (r.differences.nil? || r.differences.empty?) && r.designed_verdict.nil?
        puts r.report.to_s.split("\n").map { |l| "  #{l}" }.join("\n")
      end
      @results.none? { |r| %w[fail error].include?(r.verdict) }
    end

    def write_reports(minitest_version)
      doc = Reports.summary(
        dir: @dir, results: @results,
        meta: { run: { "dir" => @dir, "started" => @started,
                       "wall_s" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at).round(3),
                       "jobs" => @options[:jobs], "require_all" => ENV["REQUIRE_ALL"] == "1",
                       "driver" => @options[:driver], "kill_after_s" => KILL_AFTER_S },
                selection: { "matrix" => @options[:matrix], "expect" => @expect_path,
                             "filters" => @options[:filters], "selected" => @cases.length },
                env: { "ruby" => RUBY_VERSION, "minitest" => minitest_version, "json" => JSON::VERSION,
                       "platform" => RUBY_PLATFORM } }
      )
      Reports.junit(dir: @dir, doc: doc)
      warn "harness: #{doc['totals'].map { |k, v| "#{k} #{v}" }.join(' ')}; summary #{File.join(@dir, 'summary.json')}"
      doc
    end
  end
end

# ------------------------------------------------------------------- the main
def main(argv) # rubocop:disable Metrics/MethodLength
  options = Harness::CLI.parse(argv)
  if options[:help]
    print Harness::CLI.usage
    return 0
  end
  run = Harness::Run.new(options)
  if options[:list]
    run.cases.each { |k| puts k["case_id"] }
    return 0
  end
  # Read the expectations once, here, so that a bad or missing file stops the
  # whole run before a case starts rather than racing between threads.
  run.runner

  # Under either driver the reports are written BEFORE the status is returned,
  # for the reason drive_plain states: a run that is already red still writes the
  # document naming every row, the skipped and the failed alike, and the status
  # is the last thing that happens rather than the first.
  if options[:driver] == "plain"
    ok = run.drive_plain
    run.write_reports(nil)
    return ok ? 0 : 1
  end

  # minitest as the scheduling shell (0009 item 9). MT_CPU is read when
  # minitest is required, so the cap is set first; the gate above enforces it
  # whatever the scheduler decides.
  ENV["MT_CPU"] = options[:jobs].to_s
  require "minitest"
  suite = Class.new(Minitest::Test) do
    parallelize_me!
    define_method(:harness_run) { run }
    # ONE place says a verdict in minitest's words, so that a case and an
    # accounting step reach the report through the same four doors.
    define_method(:judge) do |result|
      case result.verdict
      when "pass" then assert(true, result.kase["case_id"])
      when "skip" then skip(result.reason)
      when "fail" then flunk(result.report)
      # A raised error is minitest's `error`, which is what item 7 asks for:
      # it is counted apart from a failure and is never a pass.
      else raise Harness::CaseError, result.report
      end
    end
  end
  Object.const_set(:DoomCoreHarnessCases, suite)
  run.cases.each_with_index do |kase, i|
    suite.send(:define_method, format("test_%04d_%s", i, kase["case_id"].gsub(/[^A-Za-z0-9]+/, "_"))) do
      judge(harness_run.run_case(kase))
    end
  end
  # The accounting steps get a test method each, for the same reason the cases
  # do: under this driver the exit status is minitest's, so a step that only
  # landed in the reports would leave the gate green while it failed.
  run.accounting.each_with_index do |kase, i|
    suite.send(:define_method, format("test_accounting_%04d_%s", i, kase["case_id"].gsub(/[^A-Za-z0-9]+/, "_"))) do
      judge(harness_run.run_accounting(kase))
    end
  end
  ok = Minitest.run([])
  run.write_reports(Minitest::VERSION)
  ok ? 0 : 1
rescue Harness::Refusal => e
  warn "run.rb: #{e.message}"
  2
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
