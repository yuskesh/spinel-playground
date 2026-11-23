#!/usr/bin/env ruby
# frozen_string_literal: true
#
# examples/tools/kern_sig.rb — makes the boundary signature (sig.json / kern_sig.json)
# from the generated `spinel_freestanding*.h`. **Never copy it by hand**: a bug was found
# in practice in the gap between the header and the code behind it.
#
#   kern_sig.rb <header> <out.json> <label>
#
# **A copy of the predecessor's frozen Python scripts**
# (`frozen/kern_sig_{gatekeeper,edgetwin}.py`, not in this repository. The two differ only
# in a print label and a comment, so the Ruby takes the label as an argument).
#
# It copies the spelling of `json.dump(..., indent=1)`: **one space per level**, `": "`,
# `,` at the end of a line, and **no newline at the end**.

BIG = %w[int64_t uint64_t].freeze

# The spelling of Python's `json.dump(obj, f, indent=1)`. Only
# Hash / Array / String / true / false reach here.
def dump(obj, level = 0)
  pad = " " * (level + 1)
  case obj
  when Hash
    return "{}" if obj.empty?

    "{\n" + obj.map { |k, v| "#{pad}#{jstr(k)}: #{dump(v, level + 1)}" }.join(",\n") +
      "\n" + " " * level + "}"
  when Array
    return "[]" if obj.empty?

    "[\n" + obj.map { |v| "#{pad}#{dump(v, level + 1)}" }.join(",\n") +
      "\n" + " " * level + "]"
  when String then jstr(obj)
  when true then "true"
  when false then "false"
  else raise "unsupported: #{obj.class}"
  end
end

def jstr(str)
  out = +'"'
  str.each_char do |ch|
    out << case ch
           when '"' then '\\"'
           when "\\" then "\\\\"
           when "\n" then "\\n"
           when "\r" then "\\r"
           when "\t" then "\\t"
           else
             o = ch.ord
             o < 0x20 ? format("\\u%04x", o) : ch
           end
  end
  out << '"'
end

def main(argv)
  text = File.binread(argv[0]).force_encoding("UTF-8").gsub(/\r\n?/, "\n")
  sig = {}
  text.scan(/^\s*(\w+)\s+(spinel_\w+)\s*\(([^)]*)\);/) do
    ret = Regexp.last_match(1)
    name = Regexp.last_match(2)
    params = Regexp.last_match(3).strip
    next if ret == "void"        # the trap hook goes the other way

    ps = ["", "void"].include?(params) ? [] : params.split(",", -1).map(&:strip)
    sig[name] = { "export" => name, "params" => ps, "returns" => ret,
                  "big" => ps.map { |p| BIG.include?(p) }, "retbig" => BIG.include?(ret) }
  end
  File.binwrite(argv[1], dump(sig))
  $stdout.write(format("%s: %d exported boundaries\n", argv[2], sig.size))
end

main(ARGV) if $PROGRAM_NAME == __FILE__
