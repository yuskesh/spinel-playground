#!/usr/bin/env ruby
# frozen_string_literal: true
#
# E063: the three-way join, lifted out of run_gates.sh's Python heredoc
# (E176 / P014 Phase 4).  The decision rules are a VERBATIM port -- the tracked
# `gates.tsv` is byte-compared against the Python version's output.
#
#   ruby e063_gates.rb <cases.json> <host.tsv> <node.tsv> <E040/gates.tsv>
#
# Three columns of answers: the host (native, C back end, 64-bit Integer then
# bignum), wasm (this experiment) and the Cortex-M33 (E040's recorded QEMU
# output, read out of gates.tsv).  The MCU column is what makes this a
# THREE-way check: `same` means the same characters on all three.
#
# The header row is printed by run_gates.sh, not here (as it was when the
# heredoc was Python).
require "json"

cases = JSON.parse(File.read(ARGV[0]))

host = {}
File.foreach(ARGV[1]) do |l|
  next unless l.include?("\t")

  k, v = l.chomp("\n").split("\t", -1)[0, 2]
  host[k] = v
end

wasm = {}
File.read(ARGV[2]).split("\n")[1..].to_a.each do |l|
  f = l.split("\t", -1)
  wasm[f[0]] = f[1]
end

m33 = {}
File.read(ARGV[3]).split("\n")[1..].to_a.each do |l|
  f = l.split("\t", -1)
  m33[f[2]] = f[5] if !f.empty? && f[0] == "m33"
end

cases.each do |c|
  h = host.fetch(c["case"], "")
  w = wasm.fetch(c["case"], "")
  m = m33.fetch(c["case"], "")
  v = if w.nil? || w.empty?
        "MISSING"
      elsif c["expect"] == "same"
        # A `same` row must be identical characters on the host AND on the MCU;
        # the MCU column is informational only when E040 has no row for it.
        h == w && (m.nil? || m.empty? || m == w) ? "PASS" : "FAIL"
      else
        h != w ? "PASS" : "FAIL"
      end
  puts [c["idx"].to_s, c["case"], c["expect"], h, w, m, v].join("\t")
end
