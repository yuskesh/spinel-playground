# frozen_string_literal: true
#
# tests/doom-core/refusals.rb — every "not implemented" raise of the original, accounted for.
#
#   ruby tests/doom-core/refusals.rb [--lib DIR] [TABLE]
#
# Reads tools/doom/core-refusals.tsv. A raise of LevelError in the Game files
# (game, mapmove, specials, enemy, inter, pspr, sight) whose message says it is
# not implemented, unimplemented, unknown or reached must match exactly one row
# (by file and message prefix), and every row one such raise. A row's port
# definition must exist in examples/doom/core and refuse with
# core_fail(:capacity); a `scenario:` row must name a `stops` scenario whose
# `stop_in` is that definition; a `claim:` row must be a claim on a
# core-migrated.tsv row (content-scan.rb checks the claim itself). `unchecked:`
# rows are printed as the limit they are.
require "tmpdir"
ROOT = File.expand_path("../..", __dir__)
lib = (i = ARGV.index("--lib")) ? ARGV.slice!(i, 2).last : File.join(ROOT, "examples/doom/lib/doom")
table = ARGV[0] || File.join(ROOT, "tools/doom/core-refusals.tsv")
require File.join(ROOT, "tests/doom-core/scenarios")
errors = []
rows = File.readlines(table).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
rows.each { |r| r.length == 4 or errors << "refused #{r.first}: #{r.length} column(s), want 4" }
FILES = %w[game.rb mapmove.rb specials.rb enemy.rb inter.rb pspr.rb sight.rb].freeze
raises = []
FILES.each do |f|
  File.read(File.join(lib, f)).scan(/raise LevelError,\s*"((?:[^"\\]|\\.)*)"/) do |(msg)|
    next unless msg =~ /not implemented|unimplemented|unknown|reached/i
    raises << [f, msg]
  end
end
raises.each do |f, msg|
  hits = rows.select { |r| r[0] == f && msg.start_with?(r[1]) }
  hits.length == 1 or errors << "refused #{f}: raise \"#{msg}\" matches #{hits.length} row(s)"
end
rows.each do |r|
  raises.any? { |f, msg| r[0] == f && msg.start_with?(r[1]) } or errors << "refused row #{r[0]} \"#{r[1]}\": no such raise"
end
port = Dir[File.join(ROOT, "examples/doom/core/{src,knot}/*.rb")].map { |f| File.read(f) }.join("\n")
migrated = File.read(File.join(ROOT, "tools/doom/core-migrated.tsv"))
counts = Hash.new(0)
rows.each do |file, msg, pdef, ev|
  kind = ev[/\A(\w+)/, 1]
  counts[kind] += 1
  if pdef != "-"
    body = port[/^def #{Regexp.escape(pdef)}\(.*?^end\n/m] ||
           port[/^def #{Regexp.escape(pdef.sub(/\Adc_st_kp_/, 'dc_kn_'))}\b.*?^end\n/m]
    body or (errors << "refused #{file} \"#{msg}\": no port definition #{pdef}"; next)
    body.include?("core_fail(:capacity)") or errors << "refused #{file} \"#{msg}\": #{pdef} does not refuse"
  end
  case kind
  when "full"
    sc = Scenarios::ALL[ev.delete_prefix("full:")]
    sc or (errors << "refused #{file} \"#{msg}\": no scenario #{ev}"; next)
    (sc[:stops] && sc[:full_refuses] && sc[:stop_in] == pdef) or
      errors << "refused #{file} \"#{msg}\": #{ev} is not a Full refusal with a backstop in #{pdef}"
    require File.join(ROOT, "examples/doom/core/full/session")
    Doom::Core::Session.method_defined?(:before_step!) or errors << "refused #{file} \"#{msg}\": Full has no pre-step check"
    migrated.include?("guarded-by-full:") or errors << "refused #{file} \"#{msg}\": no ledger row says Full guards it"
  when "scenario"
    sc = Scenarios::ALL[ev.delete_prefix("scenario:")]
    sc or (errors << "refused #{file} \"#{msg}\": no scenario #{ev}"; next)
    (sc[:stops] && sc[:stop_in] == pdef) or errors << "refused #{file} \"#{msg}\": #{ev} is not a stop in #{pdef}"
  when "claim"
    migrated.include?(ev.delete_prefix("claim:")) or errors << "refused #{file} \"#{msg}\": no ledger row carries #{ev}"
  when "setup"
    pdef == "-" or errors << "refused #{file} \"#{msg}\": a setup raise has no port definition"
  when "unchecked"
    puts "refusals: LIMIT #{file} \"#{msg}\": #{ev.delete_prefix('unchecked:')}"
  else
    errors << "refused #{file} \"#{msg}\": evidence #{ev.inspect}"
  end
end
errors.each { |e| puts e }
puts "refusals: #{raises.length} raise(s), #{rows.length} row(s): " +
     counts.sort.map { |k, v| "#{v} #{k}" }.join(", ") + (errors.empty? ? "; all accounted for" : "; #{errors.length} refused")
exit(errors.empty? ? 0 : 1)
