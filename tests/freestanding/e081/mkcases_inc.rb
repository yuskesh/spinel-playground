#!/usr/bin/env ruby
# frozen_string_literal: true
#
# mkcases_inc.rb (E081) -- generates the `cases.inc` that the Zephyr driver
# `results/E081/zephyr/src/main.c` includes, from the tracked `cases.json`. A
# Ruby version writing the same text as `make_cases_inc()` in the frozen Python
# `results/E081/mkcases.py` (no Python is added to the published tree).
#
#   ruby mkcases_inc.rb docs/experiments/results/E081/cases.json > gen/cases.inc
require "json"

spec = JSON.parse(File.read(ARGV.fetch(0)))
out = ["static void e081_run(void) {"]
spec.fetch("cases").each do |c|
  conv = { "int" => "E081_CASE_I", "float" => "E081_CASE_F" }.fetch(c["kind"])
  args = c["args"].map { |a| a["t"] == "i64" ? "INT64_C(#{a['v']})" : a["v"].to_s }
  out << "\t#{conv}(\"#{c['name']}\", #{c['sym']}(#{args.join(', ')}));"
end
out << "}"
puts out.join("\n")
