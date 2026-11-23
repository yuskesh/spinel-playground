#!/usr/bin/env ruby
# frozen_string_literal: true
#
# examples/tools/post_fmt.rb — for the edge-twin demo. Reads the output of
# `curl -w '\n  HTTP %{code}\n'` and puts it on one line (`post` in `run_demo.sh`).
#
# **A copy of the predecessor's frozen Python script `frozen/post_fmt.py`** (not in this
# repository), including the branch that prints a non-JSON reply as it is.
require "json"

raw = $stdin.read.split("\n  HTTP ", -1)
# Python's `rsplit(sep, 1)`: split **only once, from the right**.
if raw.size > 2
  raw = [raw[0..-2].join("\n  HTTP "), raw[-1]]
end
begin
  d = JSON.parse(raw[0])
  raise TypeError unless d.is_a?(Hash)
rescue StandardError
  $stdout.write("  " + raw[0].strip + "\n")
  exit
end
$stdout.write(format("  verdict = %s   HTTP %s\n", d["verdict"], raw[1].to_s.strip))
$stdout.write("  " + d["error"] + "\n") if d["error"]
$stdout.write(format("  trap code=%s %s\n", d["code"], d["detail"])) if d["detail"]
(d["findings"] || []).first(3).each do |f|
  $stdout.write(format("  row %-5s %-12s device says %-22s edge computes %s\n",
                       f["row"], f["field"], f["claimed"], f["computed"]))
end
