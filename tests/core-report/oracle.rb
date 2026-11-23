# frozen_string_literal: true
#
# tests/core-report/oracle.rb -- is a reported bound really a bound?
#
#   ruby oracle.rb --fixture loops.rb --expect expect.tsv --grid oracle.tsv \
#                  --reports DIR
#
# The reference is CRuby running the fixture source, not the analysis that
# produced the report. Every loop in the fixtures counts itself into its own
# cell of `cnt`, so after a call the cell says how many times the loop body ran.
# For every grid point this evaluates each reported bound for the same
# arguments with an evaluator written from the documented grammar
# (CoreReport::Expr), and requires:
#
#   * a loop's count <= the sum of its occurrences' iterations;
#   * the loops' total <= the work bound;
#   * a loop or work bound marked `tight` is REACHED at some grid point where
#     it is positive, so a bound that is sound only because it is too large
#     does not pass -- reaching zero where the loop never runs proves nothing.
#
# Only loops and work bounds with a `tight` or `upper` mark are run; an
# `unknown` one has no bound to check.
#
# oracle.tsv: `entry<TAB>name=spec ...`, where a spec is `lo..hi` for a scalar,
# `[v,v,...]` for the `buf` buffer, or `lo..hi` for `cnt`, which ranges its
# length. `cnt` defaults to four cells; `n_cnt` and `n_buf` are the lengths.

require "json"
require "optparse"
require_relative "lib"

opt = {}
OptionParser.new do |o|
  o.on("--fixture FILE") { |v| opt[:fixture] = v }
  o.on("--expect FILE") { |v| opt[:expect] = v }
  o.on("--grid FILE") { |v| opt[:grid] = v }
  o.on("--reports DIR") { |v| opt[:reports] = v }
end.parse!
%i[fixture expect grid reports].each { |k| abort "oracle.rb: --#{k} is required" unless opt[k] }

load File.expand_path(opt[:fixture])

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

def spec(text)
  if text.start_with?("[")
    JSON.parse(text)
  elsif text =~ /\A(-?\d+)\.\.(-?\d+)\z/
    (Regexp.last_match(1).to_i..Regexp.last_match(2).to_i).to_a
  else
    raise ArgumentError, "bad grid spec #{text.inspect}"
  end
end

rows = CoreReport.expectations(opt[:expect]).group_by { |r| r["entry"] }
grid = File.readlines(opt[:grid], chomp: true).reject { |l| l.start_with?("#") || l.strip.empty? }

grid.each do |line|
  entry, specs = line.split("\t", 2)
  specs = (specs || "").split(" ").to_h { |s| n, v = s.split("=", 2); [n, spec(v)] }
  report = JSON.parse(File.binread(File.join(opt[:reports], "#{entry}.json")).force_encoding(Encoding::UTF_8))
  lb = report["properties"]["loop_bound"]
  terms = lb["work_bound"]["terms"].group_by { |t| t["loop"] }
  checked = (rows[entry] || []).select { |r| r["tight"] != "-" }
  if checked.empty?
    ok("#{entry}: the grid names an entry with a bound to check", false)
    next
  end

  params = method(entry.to_sym).parameters.map { |_, n| n.to_s }
  axes = params.map do |p|
    case p
    when "n_cnt", "n_buf" then [nil]
    when "cnt" then specs.fetch("cnt", [4])
    when "buf" then [specs.fetch("buf")]
    else specs.fetch(p) { raise ArgumentError, "#{entry}: no grid for #{p}" }
    end
  end
  combos = axes.reduce([[]]) { |acc, axis| acc.product(axis).map { |a, v| a + [v] } }

  reached = Hash.new(false)
  failure = {}
  combos.each do |combo|
    env = {}
    cnt = nil
    args = params.each_with_index.map do |p, i|
      case p
      when "cnt" then cnt = Array.new(combo[i], 0)
      when "buf" then combo[i].dup
      else combo[i]
      end
    end
    params.each_with_index do |p, i|
      if p == "n_cnt" then args[i] = cnt.length
      elsif p == "n_buf" then args[i] = args[params.index("buf")].length
      end
      env[p] = args[i] unless %w[cnt buf].include?(p)
    end
    send(entry.to_sym, *args)

    total = 0
    checked.each do |row|
      next if row["subject"] == "work"
      observed = cnt[row["counter"].to_i]
      total += observed
      list = terms[row["subject"]] || []
      bound = begin
        raise ArgumentError, "an occurrence has no bound" if list.empty? || list.any? { |t| t["iterations"].nil? }
        list.sum { |t| CoreReport::Expr.evaluate(t["iterations"], env) }
      rescue ArgumentError => e
        failure[row["subject"]] ||= "#{env}: #{e.message}"
        next
      end
      failure[row["subject"]] ||= "#{env}: counted #{observed}, bound #{bound}" if observed > bound
      # Reaching a bound of zero proves nothing: a bound one too large is
      # still zero wherever the loop does not run.
      reached[row["subject"]] = true if observed == bound && bound.positive?
    end
    work = checked.find { |r| r["subject"] == "work" }
    next unless work
    begin
      bound = CoreReport::Expr.evaluate(lb["work_bound"]["expression"].to_s, env)
      failure["work"] ||= "#{env}: counted #{total}, bound #{bound}" if total > bound
      reached["work"] = true if total == bound && bound.positive?
    rescue ArgumentError => e
      failure["work"] ||= "#{env}: #{e.message}"
    end
  end

  checked.each do |row|
    subject = row["subject"]
    ok("#{entry}: #{subject} never exceeds its bound over #{combos.length} runs",
       !failure.key?(subject), failure[subject])
    next unless row["tight"] == "tight"
    ok("#{entry}: #{subject} reaches its bound", reached[subject])
  end
end

puts "oracle: #{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
