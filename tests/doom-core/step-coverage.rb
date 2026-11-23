# frozen_string_literal: true
#
# tests/doom-core/step-coverage.rb — what the step comparisons ran, over the step units.
#
#   ruby tests/doom-core/step-coverage.rb DEMO_JSON... -- SCENARIO_JSON...
#
# Each JSON is a `step-diff.rb --coverage` record (Ruby's line coverage, by unit).
# The demo records alone, then the demos with the scenarios, are summed over the
# step units, and for each: the lines run out of the lines Ruby counts, and the
# definitions no line of which ran. It is the DENOMINATOR of the step
# comparisons' zeros: "0 disagreeing" holds over the lines printed here, and says
# nothing about the rest.
#
# It refuses a definition no comparison entered unless a row of
# tools/doom/core-migrated.tsv carrying an absent-in-content or
# unreached-by-construction claim names it: code nothing runs is either claimed
# unrunnable, and checked by content-scan.rb, or it is a gap. The unrun lines
# are then split between those claimed definitions and the definitions that did
# run -- the second part is branches no comparison took.
require "json"

ROOT = File.expand_path("../..", __dir__)
SRC = File.join(ROOT, "examples/doom/core/src")
UNITS = %w[stepcore.rb stepwork.rb stepmap.rb stepspec.rb stepaux.rb stepknot.rb stepplay.rb].freeze
cut = ARGV.index("--") or abort("usage: step-coverage.rb DEMO_JSON... -- SCENARIO_JSON...")
demo_paths = ARGV[0...cut]
scen_paths = ARGV[(cut + 1)..]
demo_paths.empty? and abort("step-coverage: no demo records")

sum = lambda do |paths|
  m = {}
  paths.each do |f|
    JSON.parse(File.read(f)).each do |u, lines|
      next unless UNITS.include?(u)
      m[u] ||= Array.new(lines.size)
      m[u].size == lines.size or abort("step-coverage: #{f} counts #{lines.size} lines of #{u}, another record #{m[u].size}")
      lines.each_with_index { |c, i| m[u][i] = (m[u][i] || 0) + c unless c.nil? }
    end
  end
  (UNITS - m.keys).empty? or abort("step-coverage: no record covers #{(UNITS - m.keys).join(', ')}")
  m
end
# definition -> [unit, first body line, last body line]
DEFS = {}
UNITS.each do |u|
  src = File.readlines(File.join(SRC, u))
  src.each_with_index do |ln, i|
    next unless ln =~ /\Adef (\w+)/
    name = Regexp.last_match(1)
    j = i + 1
    j += 1 until src[j] =~ /\Aend\b/
    DEFS[name] = [u, i + 1, j - 1]
  end
end
claimed = File.readlines(File.join(ROOT, "tools/doom/core-migrated.tsv"))
              .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
              .select { |f| f[1].to_s =~ /absent-in-content:|unreached-by-construction:/ }
              .flat_map { |f| f[1].split(",").map(&:strip) }.select { |n| n.start_with?("dc_") }.uniq

report = lambda do |label, m|
  never = DEFS.select do |_, (u, a, b)|
    body = (a..b).map { |k| m[u][k] }.compact
    !body.empty? && body.all?(&:zero?)
  end.keys
  rel = UNITS.sum { |u| m[u].count { |c| !c.nil? } }
  ran = UNITS.sum { |u| m[u].count { |c| c && c.positive? } }
  printf("step-coverage: %s: %d of %d lines (%.1f%%), %d definition(s) never entered\n",
         label, ran, rel, 100.0 * ran / rel, never.length)
  [never, rel - ran]
end

demo = sum.(demo_paths)
demo_never, = report.("demos", demo)
both = sum.(demo_paths + scen_paths)
never, unrun = report.("demos and scenarios", both)
# THE DEFINITIONS THE SCENARIOS ADD, each with the scenario records that enter
# it. The compiled objects are exercised by the demos (the route and native
# lanes play DEMO1-3); these are the definitions no demo enters, so they are
# what tests/doom-core/native-scenario-diff.rb has to carry into compiled
# execution, and which scenario carries each is this list.
only = demo_never - never
entered_by = only.to_h do |d|
  u, a, b = DEFS[d]
  [d, scen_paths.select do |f|
    lines = JSON.parse(File.read(f))[u]
    lines && (a..b).any? { |k| lines[k] && lines[k].positive? }
  end.map { |f| File.basename(f, ".json").sub(/\Asc-/, "") }]
end
puts "step-coverage: entered by the scenarios and by no demo: #{only.length}: " +
     only.map { |d| "#{d}(#{entered_by[d].empty? ? 'none' : entered_by[d].join(',')})" }.join(" ")
UNITS.each do |u|
  rel = both[u].count { |c| !c.nil? }
  printf("step-coverage:   %-12s %5d of %5d (demos %5d)\n", u, both[u].count { |c| c && c.positive? }, rel,
         demo[u].count { |c| c && c.positive? })
end
inside = 0
DEFS.each do |name, (u, a, b)|
  next unless never.include?(name)
  inside += (a..b).count { |k| both[u][k] && both[u][k].zero? }
end
puts "step-coverage: unrun #{unrun}: #{inside} inside the definitions no comparison entered, " \
     "#{unrun - inside} in branches of definitions that ran"
gaps = never - claimed
puts "step-coverage: never entered: #{never.join(' ')}"
gaps.each { |g| puts "refused #{g} is entered by no comparison and no content or construction claim names it" }
exit(gaps.empty? ? 0 : 1)
