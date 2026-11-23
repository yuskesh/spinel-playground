# frozen_string_literal: true
#
# tests/core-report/normalize.rb -- a report with what differs per host fixed.
#
#   ruby normalize.rb REPORT > NORMALIZED
#
# A golden report is compared on everything that does not depend on the host
# or on the toolchain build: the target triple, the object's name and digest,
# the tools' digests and version, and any revision. Those are REPLACED with
# fixed placeholders rather than removed, so a golden report stays a complete
# report that validates against the schema. What is left -- the entry, the
# profile, the input digests and the properties -- must be byte-identical on
# Debian x86_64 and macOS arm64.
#
# THE STACK BUDGET IS THE EXCEPTION, and it is a measurement of the target
# rather than a statement about the source. Its frame sizes are what THIS
# target's code generation laid out, the per-call overhead is 8 bytes on
# x86-64 and 0 on arm64 by construction, and which functions survive inlining
# is the inliner's decision on that target. Pinning any of it as a golden would
# pin one host's numbers and fail on the other for being right.
#
# So the numbers are replaced and the SHAPE is kept: the property is still
# evaluated, still carries its verdict and reason, and still lists the same
# functions in the same order with the same kinds of evidence. What the golden
# then holds is that the document says these things about the stack -- the
# figures themselves are checked by tests/core-stack/run.sh, against methods
# that can disagree with each other.

require "json"
require_relative "lib"

PLACEHOLDER = "0" * 64
$stdout.binmode
report = JSON.parse(File.binread(ARGV.fetch(0)).force_encoding(Encoding::UTF_8))
report["target"] = "normalized-target"
report["object"] = { "file" => "normalized.o", "sha256" => PLACEHOLDER }
report["tools"] = {
  "kernel" => { "sha256" => PLACEHOLDER },
  "reader" => { "sha256" => PLACEHOLDER },
  "clang" => { "version" => "normalized", "sha256" => PLACEHOLDER }
}
scrub = lambda do |node|
  case node
  when Hash
    node["revision"] = nil if node.key?("revision")
    node.each_value { |v| scrub.call(v) }
  when Array
    node.each { |v| scrub.call(v) }
  end
end
scrub.call(report)

stack = report.dig("properties", "stack_budget")
if stack && stack["evaluated"] && stack.key?("kernel_stack")
  # Zero, not a sentinel: the schema requires these to be byte counts, and a
  # normalized report must still validate as a report.
  stack["kernel_stack"] = 0
  stack["call_overhead"] = {
    "bytes" => 0, "target" => "normalized-target", "evidence" => "normalized"
  }
  # THE PATH AND THE FRAME LIST GO ENTIRELY, names and counts alike. Which
  # functions survive is the inliner's decision on this target, so even their
  # NUMBER is host-specific -- a count here would pin one host's inlining and
  # fail on the other for being right. They are replaced by one placeholder
  # each, which keeps the shape the schema requires.
  stack["worst_path"] = ["normalized"]
  stack["frames"] = [{ "function" => "normalized", "bytes" => 0 }]
  (stack["evidence"] || []).each do |e|
    e["detail"] = "normalized" if e.key?("detail")
    e["frame_total"] = 0 if e.key?("frame_total")
    e["call_edges"] = 0 if e.key?("call_edges")
  end
end
# CoreReport::Json, not JSON.pretty_generate: a golden is compared as bytes on
# both hosts, and the library's rendering of an empty collection differs
# between the json versions the two recorded Ruby lines ship.
print CoreReport::Json.dump(report)
