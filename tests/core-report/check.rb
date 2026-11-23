# frozen_string_literal: true
#
# tests/core-report/check.rb -- the reports against the schema and against
# tests/core-report/expect.tsv.
#
#   ruby check.rb --schema FILE --expect FILE --reports DIR
#   ruby check.rb --schema FILE --selftest REPORT
#   ruby check.rb --schema FILE --validate FILE...
#
# --reports reads DIR/<entry>.json for every entry the expectation names, and
# checks, per entry:
#
#   * the report validates against the schema;
#   * the report names the entry, the hosted-stage2 profile and the modes of
#     decision 0010's table, and evaluates only the loop bound;
#   * every expectation row holds: a loop's verdict and bound or reason, the
#     reasons and iterations of every occurrence of a loop, and the work bound;
#   * the loops in the report are exactly the loops the expectation lists, so
#     a loop that appears or disappears is a failure and not a silence;
#   * every loop's digest is sha256("v<digest_version>:<header>"), its id is
#     method#ordinal, ordinals run from 0 within a method, and a parent is an
#     earlier loop of the same method.
#
# --selftest takes one valid report and requires the validator to ACCEPT it and
# to REFUSE each of a set of damaged copies. Without it a validator that
# accepts everything would pass every other check here.

require "digest"
require "json"
require "optparse"
require_relative "lib"

opt = { validate: [] }
OptionParser.new do |o|
  o.on("--schema FILE") { |v| opt[:schema] = v }
  o.on("--expect FILE") { |v| opt[:expect] = v }
  o.on("--reports DIR") { |v| opt[:reports] = v }
  o.on("--selftest REPORT") { |v| opt[:selftest] = v }
  o.on("--json-selftest FILE") { |v| opt[:json] = v }
  o.on("--update") { opt[:update] = true }
  o.on("--validate") { opt[:validate_mode] = true }
end.parse!
opt[:validate] = ARGV.dup if opt[:validate_mode]
abort "check.rb: --schema is required" unless opt[:schema] || opt[:json]

schema = CoreReport::Schema.new(JSON.parse(File.read(opt[:schema]))) if opt[:schema]
$pass = 0
$fail = 0
def ok(name, good, detail = nil)
  if good
    puts "  pass #{name}"
    $pass += 1
  else
    puts "  FAIL #{name}#{detail ? " -- #{detail}" : ''}"
    $fail += 1
  end
end

MODES = {
  "recursion" => "enforce", "allocation" => "enforce", "loop_bound" => "observe",
  "stack_budget" => "observe", "extern_effects" => "enforce", "undefined_symbols" => "enforce"
}.freeze

# The properties a hosted-stage2 build evaluates: the loop bound since step 1,
# the stack budget since step 2. The rest carry their mode and nothing else.
EVALUATED = %w[loop_bound stack_budget].freeze

if opt[:json]
  # The cross-host contract for the canonical emitter. The fixture holds the
  # exact bytes; a json version that renders an empty collection, an escape or
  # a number differently fails HERE, rather than in a golden report on the
  # other host, where the cause is a mystery.
  text = CoreReport::Json.dump(CoreReport::Json.sample)
  rejected_path = opt[:json].sub(/\.json\z/, "-rejected.json")
  if opt[:update]
    File.binwrite(opt[:json], text)
    File.binwrite(rejected_path,
                  (CoreReport::Json.dump_legacy_empties(CoreReport::Json.sample) + "\n").b)
    puts "  wrote #{opt[:json]}"
    puts "  wrote #{rejected_path}"
  else
    want = File.exist?(opt[:json]) ? File.binread(opt[:json]) : nil
    if want.nil?
      ok("the canonical JSON fixture exists", false, opt[:json])
    else
      good = text == want
      detail = nil
      unless good
        a = text.lines
        b = want.lines
        i = a.zip(b).index { |x, y| x != y }
        detail = "line #{(i || [a.length, b.length].min) + 1}: got #{a[i].inspect}, want #{b[i].inspect}"
      end
      ok("the canonical emitter reproduces its fixture byte for byte", good, detail)
    end
  end
  # Still JSON, and still the same value: an emitter that agreed with the
  # fixture but wrote something no parser accepts would pass the line above.
  #
  # THE PARSER GETS A COPY. json 2.7.2, which Debian's ruby 3.3.8 ships,
  # FORCE-ENCODES the string it parses IN PLACE, from ASCII-8BIT to UTF-8;
  # json 2.12.2 does not. Handing it `text` made a later check about `text`
  # fail on one host and pass on the other, and nothing at that later line
  # said this one had touched its subject. The copy also survives someone
  # inserting a check between the two.
  ok("what it writes parses back to the same value",
     JSON.parse(text.dup) == CoreReport::Json.sample)
  # A JSON file's top level can be an array or an object, and a fixture whose
  # top level is an object cannot pin the other two. json 2.7.2 renders a
  # top-level empty differently again, so both are stated here.
  ok("a top-level empty array is []", CoreReport::Json.dump([]) == "[]\n".b,
     CoreReport::Json.dump([]).inspect)
  ok("a top-level empty object is {}", CoreReport::Json.dump({}) == "{}\n".b,
     CoreReport::Json.dump({}).inspect)
  ok("the bytes end in exactly one newline",
     text.end_with?("\n") && !text.end_with?("\n\n"))
  # ON A FRESH DUMP, not on `text`. The contract in lib.rb is that dump
  # RETURNS binary; that a particular string is still binary after other code
  # has handled it is a different claim, and asserting it is what made this
  # order-dependent. The deliberate parse below is the control: it mutates its
  # own object the way json 2.7.2 does, and the answer must not move.
  victim = CoreReport::Json.dump(CoreReport::Json.sample)
  JSON.parse(victim)
  ok("the bytes are binary, so no locale can transcode them",
     CoreReport::Json.dump(CoreReport::Json.sample).encoding == Encoding::BINARY)
  # THE DEMONSTRATED REJECTION. A comparison nobody has seen fail is a
  # comparison nobody knows can fail, so the input that fails it is kept in the
  # branch: the same value rendered the way the json version on the other host
  # renders it, which is what the gate actually refused.
  if File.exist?(rejected_path)
    rejected = File.binread(rejected_path)
    # A copy here too: `rejected` is compared as bytes two lines down, and this
    # is the same shape as the defect above, one statement short of it.
    ok("the rejected rendering is the SAME value, so this is about bytes and not content",
       JSON.parse(rejected.dup) == CoreReport::Json.sample)
    ok("the emitter does not produce it, so the comparison can fail", text != rejected)
    differing = text.lines.zip(rejected.lines).count { |a, b| a != b }
    ok("and it differs, in the empty-collection lines", differing.positive?,
       "#{differing} line(s) differ")
  else
    ok("the rejected rendering is kept in the branch", false, rejected_path)
  end
  ok("invalid UTF-8 is refused rather than written out",
     begin
       CoreReport::Json.dump({ "x" => 255.chr })
       false
     rescue ArgumentError
       true
     end)
  ok("it refuses a float, which has no canonical rendering here",
     begin
       CoreReport::Json.dump({ "x" => 1.5 })
       false
     rescue ArgumentError
       true
     end)
end

opt[:validate].each do |path|
  next ok("#{File.basename(path)} exists", false, path) unless File.exist?(path)
  errors = schema.validate(JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8)))
  ok("#{File.basename(path)} validates against the schema", errors.empty?, errors.first(3).join("; "))
end

if opt[:selftest]
  base = JSON.parse(File.binread(opt[:selftest]).force_encoding(Encoding::UTF_8))
  ok("selftest: the unmodified report is accepted", schema.validate(base).empty?,
     schema.validate(base).first(3).join("; "))
  damage = {
    "a required key removed" => ->(r) { r.delete("profile") },
    "an unknown top-level key" => ->(r) { r["extra"] = 1 },
    "an unknown profile" => ->(r) { r["profile"] = "bare-metal" },
    "evaluated true with no verdict" => ->(r) { r["properties"]["recursion"]["evaluated"] = true },
    "a verdict on a property not evaluated" => ->(r) { r["properties"]["extern_effects"]["verdict"] = "pass" },
    # The stack budget's three shapes are distinguished by what they carry, so
    # a verdict without the measurement that decided it must not validate.
    "a stack verdict with no kernel_stack" => ->(r) { r["properties"]["stack_budget"].delete("kernel_stack") },
    "a stack frame that is not a number" => lambda { |r|
      r["properties"]["stack_budget"]["frames"][0]["bytes"] = "48"
    },
    "an unevaluated stack budget with no reason" => lambda { |r|
      r["properties"]["stack_budget"] = { "mode" => "observe", "evaluated" => false }
    },
    "a loop verdict outside the enum" => ->(r) { r["properties"]["loop_bound"]["loops"][0]["verdict"] = "maybe" },
    "a passing loop with a reason" => ->(r) { r["properties"]["loop_bound"]["loops"][0]["reason"] = "bound-varies" },
    "a passing loop with no evidence" => ->(r) { r["properties"]["loop_bound"]["loops"][0]["evidence"] = [] },
    "an unknown evidence kind" => ->(r) { r["properties"]["loop_bound"]["evidence"][0]["kind"] = "guess" },
    "a digest that is not sha256" => ->(r) { r["properties"]["loop_bound"]["loops"][0]["digest"] = "abc" },
    "an unknown reason code" => lambda { |r|
      l = r["properties"]["loop_bound"]["loops"][0]
      l.merge!("verdict" => "unknown", "reason" => "too-hard", "evidence" => [])
    },
    "pass with an unknown work bound" => ->(r) { r["properties"]["loop_bound"]["work_bound"]["expression"] = nil },
    "a work expression outside the grammar" => lambda { |r|
      r["properties"]["loop_bound"]["evidence"][0]["value"]["expression"] = "i@12 + 1"
    }
  }
  damage.each do |name, edit|
    copy = JSON.parse(JSON.generate(base))
    edit.call(copy)
    ok("selftest: refused, #{name}", !schema.validate(copy).empty?)
  end
end

if opt[:reports]
  abort "check.rb: --reports needs --expect" unless opt[:expect]
  rows = CoreReport.expectations(opt[:expect])
  rows.group_by { |r| r["entry"] }.each do |entry, erows|
    path = File.join(opt[:reports], "#{entry}.json")
    unless File.exist?(path)
      ok("#{entry}: a report exists", false, path)
      next
    end
    report = JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
    errors = schema.validate(report)
    ok("#{entry}: validates against the schema", errors.empty?, errors.first(3).join("; "))
    ok("#{entry}: names its entry and profile",
       report["entry"] == entry && report["profile"] == "hosted-stage2",
       "#{report['entry']} #{report['profile']}")
    props = report["properties"] || {}
    ok("#{entry}: the modes are hosted-stage2's and only the derived properties are evaluated",
       MODES.all? { |k, m| props.dig(k, "mode") == m && props.dig(k, "evaluated") == EVALUATED.include?(k) })
    # The stack budget is derived, but its VERDICT is not: hosted-stage2
    # declares neither term of the inequality, so a report that claimed `pass`
    # here would be claiming a policy nobody wrote.
    ok("#{entry}: the stack budget is measured and its verdict is unknown",
       props.dig("stack_budget", "verdict") == "unknown" &&
         props.dig("stack_budget", "kernel_stack").is_a?(Integer),
       "#{props.dig('stack_budget', 'verdict')} #{props.dig('stack_budget', 'kernel_stack')}")
    lb = props["loop_bound"] || {}
    loops = (lb["loops"] || []).to_h { |l| [l["id"], l] }
    terms = (lb.dig("work_bound", "terms") || []).group_by { |t| t["loop"] }

    listed = erows.map { |r| r["subject"] }.reject { |s| s == "work" || s.start_with?("term:") }
    ok("#{entry}: the report's loops are exactly the expected ones",
       loops.keys.sort == listed.sort, "report #{loops.keys.sort} expected #{listed.sort}")

    erows.each do |row|
      extra = CoreReport.extras(row["extra"])
      subject = row["subject"]
      if subject == "work"
        verdict = lb["verdict"]
        good = verdict == row["verdict"]
        if good && verdict == "pass"
          good = lb.dig("work_bound", "expression") == row["value"] &&
                 lb.dig("evidence", 0, "value", "expression") == row["value"]
        end
        # A limit the analysis met is named, and no limit is `null`: a work
        # bound that quietly stopped early would otherwise read as one that
        # could not be derived.
        good &&= lb.dig("work_bound", "limit") == extra["limit"]
        ok("#{entry}: work bound #{row['verdict']} #{row['value']}#{extra['limit'] ? " limit #{extra['limit']}" : ''}",
           good,
           "#{verdict} #{lb.dig('work_bound', 'expression').inspect} limit=#{lb.dig('work_bound', 'limit').inspect}")
      elsif subject.start_with?("term:")
        id = subject.delete_prefix("term:")
        list = terms[id] || []
        good = !list.empty? && list.all? do |t|
          if row["verdict"] == "pass"
            t["iterations"] == row["value"] && t["reason"].nil?
          else
            t["iterations"].nil? && t["reason"] == row["value"] &&
              (!extra["detail"] || t["detail"].to_s.start_with?(extra["detail"]))
          end
        end
        ok("#{entry}: every occurrence of #{id} is #{row['value']}", good,
           list.map { |t| [t["iterations"], t["reason"], t["detail"]] }.inspect)
      else
        l = loops[subject]
        next ok("#{entry}: #{subject} is reported", false) unless l
        good = l["verdict"] == row["verdict"]
        got = row["verdict"] == "pass" ? l.dig("evidence", 0, "value", "expression") : l["reason"]
        good &&= got == row["value"]
        good &&= l["detail"].to_s.start_with?(extra["detail"]) if extra["detail"]
        if extra["conjunct"]
          good &&= l.dig("conjunct", "index") == extra["conjunct"].to_i
        elsif row["verdict"] == "pass"
          good &&= l["conjunct"].nil?
        end
        good &&= l["parent"] == extra["parent"] if extra["parent"]
        ok("#{entry}: #{subject} #{row['verdict']} #{row['value']}", good,
           "#{l['verdict']} #{got.inspect} detail=#{l['detail'].inspect} conjunct=#{l['conjunct'].inspect}")
      end
    end

    by_method = (lb["loops"] || []).group_by { |l| l["method"] }
    ok("#{entry}: every digest is sha256 of the versioned header",
       (lb["loops"] || []).all? { |l| l["digest"] == Digest::SHA256.hexdigest("v#{l['digest_version']}:#{l['header']}") })
    ok("#{entry}: ids are method#ordinal, ordinals run from 0, parents are earlier loops",
       by_method.all? do |m, ls|
         ords = ls.map { |l| l["ordinal"] }
         ords.sort == (0...ls.length).to_a &&
           ls.all? { |l| l["id"] == "#{m}##{l['ordinal']}" } &&
           ls.all? do |l|
             next true if l["parent"].nil?
             p = ls.find { |q| q["id"] == l["parent"] }
             p && p["ordinal"] < l["ordinal"]
           end
       end)
  end
end

puts "check: #{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
