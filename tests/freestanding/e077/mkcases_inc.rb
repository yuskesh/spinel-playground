#!/usr/bin/env ruby
# frozen_string_literal: true
#
# mkcases_inc.rb -- generates E077's `cases.inc` (the C case bodies the Zephyr
# driver `zephyr/src/main.c` includes) **from the tracked `cases.json`**. It
# writes the same text as `make_cases_inc()` in the frozen Python
# `results/E077/mkcases.py`, in Ruby (no Python is added to the published
# tree). Its only input is cases.json.
#
#   ruby mkcases_inc.rb docs/experiments/results/E077/cases.json > gen/cases.inc
require "json"

C_ELEM = { "u8" => "uint8_t", "i32" => "int32_t", "f32" => "float", "f64" => "double" }.freeze

spec = JSON.parse(File.read(ARGV.fetch(0)))
fixtures = spec.fetch("fixtures")
cases = spec.fetch("cases")
fx = fixtures.to_h { |f| [f["name"], f] }

def c_lit(v)
  v.is_a?(Float) ? v.to_s : v.to_s
end

out = []
fixtures.each do |f|
  vals = f["init"]
  lit = vals.map { |v| c_lit(v) }.join(", ")
  out << "static #{C_ELEM.fetch(f['elem'])} bf_#{f['name']}[#{[1, vals.size].max}] = {#{lit.empty? ? '0' : lit}};"
end
out << ""
out << "static void e077_reset(void) {"
fixtures.each do |f|
  f["init"].each_with_index { |v, i| out << "\tbf_#{f['name']}[#{i}] = #{c_lit(v)};" }
end
out << "}"
out << ""
out << "static void e077_run(void) {"
cases.each do |c|
  out << "\te077_reset();"
  conv = { "int" => "E077_CASE_I", "float" => "E077_CASE_F" }.fetch(c["kind"])
  args = c["args"].map { |a| a.key?("buf") ? "bf_#{a['buf']}" : a["lit"].to_s }
  out << "\t#{conv}(\"#{c['name']}\", #{c['sym']}(#{args.join(', ')}));"
  c["setup"].each { |s| out << "\tE077_BUF_#{fx.fetch(s)['elem'].upcase}(bf_#{s});" }
  out << "\tE077_EOL();"
end
out << "}"
puts out.join("\n")
