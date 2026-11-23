# frozen_string_literal: true
#
# tools/doom/source-elements.rb — the source entries' buffer elements, from the
# fields they are handed.
#
#   ruby tools/doom/source-elements.rb [--root DIR] (--check | --write)
#
# The source entries of tests/doom-core/fixtures/source take the resident
# fields their contexts hand them (fields.tsv there): a buffer parameter bound
# to a field of examples/doom/core/state.tsv must declare that field's element,
# which tests/doom-core/source-registry.rb requires, and which decision 0018
# changes when it narrows a field (examples/doom/core/widths.tsv). The
# contracts are otherwise written by hand; this writes only that one word of
# each such `param NAME buffer ELEMENT ...` line, from the schema.
#
# A parameter every context hands a field takes that field's element; one that
# two contexts hand fields of different elements is refused, because one
# contract cannot declare both. `state` is core_state, i64. A parameter handed
# nothing resident -- `none`, `arg:`, `job:`, `derived:` -- keeps the element
# its contract states, as does a scalar parameter. A binding to a field
# state.tsv does not have is refused: a field that became an alias or was
# removed would otherwise leave its contract's element unchecked.
#
# --check exits 1 naming every contract line that differs from what --write
# would make; --write rewrites those lines and nothing else.

require "optparse"

opt = { root: File.expand_path("../..", __dir__) }
OptionParser.new do |o|
  o.on("--root DIR") { |v| opt[:root] = v }
  o.on("--check") { opt[:mode] = :check }
  o.on("--write") { opt[:mode] = :write }
end.parse!
opt[:mode] or abort("usage: source-elements.rb [--root DIR] (--check | --write)")

FIX = File.join(opt[:root], "tests/doom-core/fixtures/source")
def rows(path)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
end

element = rows(File.join(opt[:root], "examples/doom/core/state.tsv")).to_h { |r| [r[0], r[2]] }
element["core_state"] = "i64"

want = Hash.new { |h, k| h[k] = {} }
refused = []
rows(File.join(FIX, "fields.tsv")).each do |ctx, entry, param, field, _use|
  next if field == "none" || field.start_with?("arg:", "job:", "derived:")
  unless element.key?(field)
    refused << "#{entry} #{param}: #{ctx} hands #{field}, which state.tsv does not have"
    next
  end
  want[[entry, param]][field] = [element[field], ctx]
end

lines = 0
changed = []
Dir[File.join(FIX, "*.contract")].sort.each do |path|
  entry = File.basename(path, ".contract") # fields.tsv names an entry by its contract file
  text = File.readlines(path)
  out = text.map do |l|
    m = l.match(/\Aparam (\S+) buffer (\S+) (.*)\z/m) or next l
    fields = want[[entry, m[1]]]
    next l if fields.empty?
    els = fields.values.map(&:first).uniq
    if els.size > 1
      refused << "#{entry} #{m[1]}: handed #{fields.map { |f, (e, c)| "#{f} (#{e}, #{c})" }.join(', ')}: " \
                 "one contract cannot declare two elements"
      next l
    end
    lines += 1
    next l if m[2] == els[0]
    changed << "#{File.basename(path)}: #{m[1]} #{m[2]} -> #{els[0]} (#{fields.keys.join(', ')})"
    "param #{m[1]} buffer #{els[0]} #{m[3]}"
  end
  File.write(path, out.join) if opt[:mode] == :write && out != text
end

refused.each { |r| puts "source-elements: refused #{r}" }
changed.each { |c| puts "source-elements: #{opt[:mode] == :write ? 'wrote' : 'differs'} #{c}" }
puts "source-elements: #{lines} bound buffer parameter(s), #{changed.size} #{opt[:mode] == :write ? 'rewritten' : 'differ'}, " \
     "#{refused.size} refused"
exit(refused.empty? && (opt[:mode] == :write || changed.empty?) ? 0 : 1)
