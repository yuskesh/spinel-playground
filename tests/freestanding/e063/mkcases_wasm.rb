#!/usr/bin/env ruby
# frozen_string_literal: true
#
# E063: the wasm side of E040's differential oracle, DERIVED from E040's table.
#
# Ruby port of `mkcases_wasm.py` (E176 / P014 Phase 4).  The output is compared
# byte-for-byte against the Python version's, so the JSON is emitted in
# **Python's `json.dump(..., indent=1)` shape**, not Ruby's `JSON.pretty_generate`
# (which indents by two).  `emit_json` below is that shape and nothing else.
#
# E040 wrote its case list once (results/E040/mkcases.rb) and generated both the
# host driver and the MCU driver from it, because a list written twice drifts.
# E063 adds a third consumer -- a JS driver -- and the same reasoning applies with
# more force, since the JS side has to get the argument TYPES right as well
# (WebAssembly's i64 is a BigInt in JS and its i32 is a Number; passing the wrong
# one is a TypeError, and passing a Number where the module wanted 2^62 is a
# silently wrong answer).
#
# So nothing is transcribed here.  The C expressions come from E040's CASES, and
# the types come from the GENERATED header (spinel_freestanding.h), which is the
# same file the boundary was declared into.  If a freestanding_def changes width,
# this file follows without being edited.
#
#     ruby mkcases_wasm.rb <spinel_freestanding.h> > cases.json

require_relative "../e040/mkcases"

# A module for the same reason E040's mkcases.rb has one: this file is also
# `require_relative`d (by E063's build.sh, for probe/sig.json), and Ruby's top
# level is shared.
module MkcasesWasm
  module_function

  CASES = Mkcases::CASES

  # int64_t / uint64_t cross the JS boundary as BigInt; everything narrower is a
  # Number.  This IS the wasm ABI (V8's BigInt integration), not a convention of
  # this script.
  BIG = ["int64_t", "uint64_t"].freeze

  # {export => [[param C types], return C type]} straight out of the generated
  # header.  Reading the header rather than the .rb is deliberate: the header is
  # what a C caller would compile against, so if it and the module disagree the
  # differential oracle is testing the wrong signature (E040 s6 found exactly
  # such a disagreement on the narrow returns).
  def header_types(path)
    sig = {}
    File.read(path).scan(/^\s*(\w+)\s+(spinel_\w+)\s*\(([^)]*)\);/) do |ret, name, params|
      params = params.strip
      # The header declares the trap hook alongside the boundaries, and it is
      # the one prototype that goes the other way (the platform defines it,
      # the module imports it).  `void` is how it is told apart without
      # hard-coding the name: a freestanding_def cannot return void
      # (tools/freestanding/README.md, "returns:"), so a void prototype in
      # this header is by construction not a boundary.
      next if ret == "void"

      ps = ["", "void"].include?(params) ? [] : params.split(",").map(&:strip)
      sig[name] = [ps, ret]
    end
    sig
  end

  # --- Python's json.dump(..., indent=1) ------------------------------------
  # Only the shapes this script emits: Integer / String / true / false / Array /
  # Hash.  Empty containers are `[]` / `{}` on one line (Python's rule); non-empty
  # ones put every element on its own line, indented by ONE space per level, with
  # `,` at the end of the line and `": "` between key and value.
  def json_scalar(v)
    case v
    when true then "true"
    when false then "false"
    when Integer then v.to_s
    when String then json_string(v)
    else raise "mkcases_wasm: no JSON spelling for #{v.class}"
    end
  end

  def json_string(s)
    out = +'"'
    s.each_char do |ch|
      out << case ch
             when '"' then '\\"'
             when "\\" then "\\\\"
             when "\n" then '\\n'
             when "\t" then '\\t'
             when "\r" then '\\r'
             else
               # Python's json.dumps defaults to ensure_ascii=True.
               c = ch.ord
               c < 0x20 || c > 0x7e ? format('\\u%04x', c) : ch
             end
    end
    out << '"'
  end

  def emit_json(v, level = 0)
    pad = " " * level
    inner = " " * (level + 1)
    case v
    when Array
      return "[]" if v.empty?

      "[\n" + v.map { |e| inner + emit_json(e, level + 1) }.join(",\n") + "\n" + pad + "]"
    when Hash
      return "{}" if v.empty?

      body = v.map { |k, e| inner + json_string(k.to_s) + ": " + emit_json(e, level + 1) }
      "{\n" + body.join(",\n") + "\n" + pad + "}"
    else
      json_scalar(v)
    end
  end

  def main
    sig = header_types(ARGV[0])
    out = []
    CASES.each_with_index do |(name, _rb, cexpr, expect), idx|
      m = /\A(\w+)\((.*)\)\z/.match(cexpr.strip)
      export = m[1]
      argtext = m[2].strip
      abort("mkcases_wasm: #{export} is not in the generated header") unless sig.key?(export)

      ptys, rty = sig[export]
      # `4611686018427387904LL` -> 4611686018427387904.  The LL suffix is C's
      # spelling of "this literal is wide"; JS says it with BigInt instead.
      args = argtext == "" ? [] : argtext.split(",").map { |a| a.strip.sub(/[Ll]+\z/, "") }
      if args.length != ptys.length
        abort(format("mkcases_wasm: %s takes %d arg(s), the case passes %d",
                     export, ptys.length, args.length))
      end
      # Key order is Python's dict insertion order, and Ruby's Hash keeps
      # insertion order too -- the byte comparison in E176 pins it.
      out << {
        "idx" => idx, "case" => name, "export" => export, "expect" => expect,
        "args" => args,
        "argbig" => ptys.map { |t| BIG.include?(t) },
        "retbig" => BIG.include?(rty),
      }
    end
    $stdout.write(emit_json(out))
    $stdout.write("\n")
  end
end

MkcasesWasm.main if __FILE__ == $PROGRAM_NAME
