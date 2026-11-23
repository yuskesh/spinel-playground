#!/usr/bin/env ruby
# frozen_string_literal: true
#
# examples/tools/forge.rb — for the edge-twin demo. Makes a copy of a log the device
# wrote with exactly one place tampered with (`forge` in `run_demo.sh`).
#
#   forge.rb <src.log> <dst.log> <ruby-expression over the row list `B`>
#
# The **function** of the predecessor's frozen Python script (`frozen/forge.py`,
# not in this repository). **Byte equality is not claimed**: the argument is "an expression on
# the array of lines `B`", and the expression itself changes from Python to Ruby. What
# is checked is that the demo looks the same (curl's output).
src, dst, edit = ARGV[0], ARGV[1], ARGV[2]
head = nil
final = nil
B = []
File.binread(src).force_encoding("UTF-8").split("\n", -1).each do |line|
  next if line.empty?

  if line.start_with?("#edge-twin") then head = line
  elsif line.start_with?("#final") then final = line
  else B << line.split("\t", -1)
  end
end
eval(edit) # rubocop:disable Security/Eval -- this takes the demo's tampering expression as it is
File.binwrite(dst, ([head] + B.map { |r| r.join("\t") } + [final]).join("\n") + "\n")
