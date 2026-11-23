# frozen_string_literal: true
#
# tests/core-report/contracts.rb -- a contract per fixture entry.
#
#   ruby contracts.rb --fixture loops.rb --root-name loops.rb --out DIR ENTRY...
#
# The fixture entries all follow one convention, so their contracts are written
# from their signatures rather than kept as fifty near-identical files: `cnt` is
# an inout i64 buffer counted by `n_cnt`, `buf` an in i64 buffer counted by
# `n_buf`, and every other parameter an i64 scalar. The signature is read by
# loading the source and asking CRuby for the method's parameters.
#
# `--int i32` makes the result and the other scalars i32, for a 32-bit target,
# which refuses an i64 scalar boundary (decision 0019, revised 2026-10-21); the
# buffers keep their i64 elements and the counts stay u64.

require "fileutils"
require "optparse"

opt = {}
OptionParser.new do |o|
  o.on("--fixture FILE") { |v| opt[:fixture] = v }
  o.on("--root-name NAME") { |v| opt[:root] = v }
  o.on("--out DIR") { |v| opt[:out] = v }
  o.on("--int TYPE", %w[i64 i32]) { |v| opt[:int] = v }
end.parse!
%i[fixture root out].each { |k| abort "contracts.rb: --#{k.to_s.tr('_', '-')} is required" unless opt[k] }

load File.expand_path(opt[:fixture])
FileUtils.mkdir_p(opt[:out])
ARGV.each do |entry|
  int = opt[:int] || "i64"
  lines = ["core-contract 1", "root #{opt[:root]}", "entry #{entry}", "result #{int}"]
  method(entry.to_sym).parameters.each do |kind, name|
    abort "contracts.rb: #{entry} has a #{kind} parameter #{name}" unless kind == :req
    lines << case name.to_s
             when "cnt" then "param cnt buffer i64 inout count n_cnt"
             when "buf" then "param buf buffer i64 in count n_buf"
             when "n_cnt", "n_buf" then "param #{name} scalar u64"
             else "param #{name} scalar #{int}"
             end
  end
  File.write(File.join(opt[:out], "#{entry}.contract"), lines.join("\n") + "\n")
end
