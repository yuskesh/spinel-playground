#!/usr/bin/env ruby
# frozen_string_literal: true
#
# E063: probe/sig.json -- the worker's view of the boundary, generated from the
# same header the C side would compile against.  Lifted out of build.sh's Python
# heredoc (E176 / P014 Phase 4); the JSON shape is Python's
# `json.dump(..., indent=1)` and there is NO trailing newline, because the
# tracked `probe/sig.json` is byte-compared against the Python version's output.
#
#   ruby mksig.rb <spinel_freestanding.h> <out.json>
#
# index.mjs must not contain a transcribed signature list for the same reason
# E031's shim table is generated: a transcription that can be wrong is a bug
# generator.
require_relative "mkcases_wasm"

sig = {}
MkcasesWasm.header_types(ARGV[0]).sort.each do |name, (ps, ret)|
  sig[name] = {
    "export" => name, "params" => ps, "returns" => ret,
    "big" => ps.map { |p| MkcasesWasm::BIG.include?(p) },
    "retbig" => MkcasesWasm::BIG.include?(ret),
  }
end
File.write(ARGV[1], MkcasesWasm.emit_json(sig))
puts format("probe/sig.json: %d exported boundaries", sig.length)
