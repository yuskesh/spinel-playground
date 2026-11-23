# frozen_string_literal: true
#
# tests/doom-core/prepared-domain.rb — every element edge, on both sides.
#
#   ruby tests/doom-core/prepared-domain.rb
#
# `Resources.prepared` packs a produced value into its element, and `pack`
# does not check a range, it WRAPS: `[-1].pack("C")` is `ff`. It used to do
# exactly that, while its comment claimed the encoder's rules. This drives a
# one-field schema and a probe object through it -- Mac review's minimal
# reproduction -- at the last valid and first invalid value of every element.
#
# THE EXPECTATIONS ARE WRITTEN OUT HERE, NOT BORROWED. Each case states its
# expected bytes or its refusal. `Reference.encode` is then run on the same
# input as a CROSS-CHECK that the two sides decide alike; it is not the source
# of the expected answer, because a candidate agreeing with the encoder it was
# copied from would prove nothing if both were wrong.
ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/core/full/resources")
require_relative File.join(ROOT, "examples/doom/core/full/reference")
require "tmpdir"

RES = Doom::Core::Resources
REF = Doom::Core::Reference

module Doom
  class Probe
    def initialize(v) = (@value = v)
  end
end

# value, element, count, expected -> hex bytes, or :refuse
CASES = [
  [0,              "u8",  1, "00"],
  [255,            "u8",  1, "ff"],
  [-1,             "u8",  1, :refuse],   # the reported wrap: ff
  [256,            "u8",  1, :refuse],
  [(1 << 31) - 1,  "i32", 1, "ffffff7f"],
  [-(1 << 31),     "i32", 1, "00000080"],
  [1 << 31,        "i32", 1, :refuse],
  [-(1 << 31) - 1, "i32", 1, :refuse],
  [0,              "u32", 1, "00000000"],
  [(1 << 32) - 1,  "u32", 1, "ffffffff"],
  [-1,             "u32", 1, :refuse],
  [1 << 32,        "u32", 1, :refuse],
  [(1 << 63) - 1,  "i64", 1, "ffffffffffffff7f"],
  [-(1 << 63),     "i64", 1, "0000000000000080"],
  [1 << 63,        "i64", 1, :refuse],   # the reported wrap: 00..80
  [-(1 << 63) - 1, "i64", 1, :refuse],
  [7,              "i64", 1, "0700000000000000"],
  [true,           "i64", 1, "0100000000000000"],   # the approved flag conversion
  [false,          "i64", 1, "0000000000000000"],
  [[1, -1, 3],     "i64", 3, "0100000000000000ffffffffffffffff0300000000000000"],
  [[1, 256],       "u8",  2, :refuse],   # an ARRAY element out of range, same path
  [nil,            "i64", 1, :refuse],   # a direct producer returning nil: an ERROR
].freeze

def run_resources(value, element, count)
  Dir.mktmpdir do |d|
    acq = File.join(d, "acq.tsv"); File.write(acq, "")
    sch = File.join(d, "state.tsv")
    File.write(sch, "p\tresource\t#{element}\tfixed:#{count}\tprepared:p\tProbe@@value\t-\n")
    out, unsup, = RES.prepared(acquired: acq, schema: sch,
                               objects: { "Doom::Probe" => Doom::Probe.new(value) })
    return [:unsupported, unsup.first&.last] unless out["p"]
    [:bytes, out["p"].unpack1("H*")]
  end
rescue Doom::Core::Resources::PreparationError => e
  [:refuse, e.message]
end

def run_reference(value, element, count)
  [:bytes, REF.encode(value, element, count).unpack1("H*")]
rescue Doom::Core::Reference::ReferenceError => e
  [:refuse, e.message]
end

fails = 0
CASES.each do |value, element, count, want|
  got_kind, got = run_resources(value, element, count)
  ref_kind, = run_reference(value, element, count)
  label = "#{value.inspect} as #{element}x#{count}"
  ok =
    if want == :refuse then got_kind == :refuse
    else got_kind == :bytes && got == want
    end
  agree = (got_kind == ref_kind)
  status = ok && agree ? "pass" : "FAIL"
  fails += 1 unless ok && agree
  detail = want == :refuse ? "refused" : got
  detail = "#{got_kind} #{got}" unless ok
  puts format("%-4s %-40s %-20s reference %s", status, label, detail,
              agree ? "agrees" : "DISAGREES (#{ref_kind})")
end
puts "prepared-domain: #{CASES.length} checked, #{CASES.length - fails} pass, #{fails} fail"
exit(fails.zero? ? 0 : 1)
