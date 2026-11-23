# frozen_string_literal: true
#
# tests/doom-core/dup-check.rb — a duplicated helper has not drifted.
#
#   ruby tests/doom-core/dup-check.rb [--root DIR] [--fixture DIR]
#
# Each pair in fixtures/source/dups.tsv names a CORE definition and a copy of it
# under another name. The copy's text, with its own name replaced by the
# original's, must equal the original's text exactly. Anything else is refused
# with the pair named: a copy that differs by one character is two definitions
# that look like one.
#
# THE DEFINITIONS ARE READ FROM TWO DIRECTORIES: the units (--root) and the
# source fixture's own units (--fixture), packed with them by
# harness/build-artifacts.sh. The column entry draws through a copy defined in
# the fixture (dc_sp_draw_column), and a copy no one reads is a copy no one
# checks.
require "optparse"

ROOT = File.expand_path("../..", __dir__)
opt = { root: File.join(ROOT, "examples/doom/core/src"),
        fixture: File.join(ROOT, "tests/doom-core/fixtures/source/src") }
OptionParser.new do |o|
  o.on("--root DIR") { |v| opt[:root] = v }
  o.on("--fixture DIR") { |v| opt[:fixture] = v }
end.parse!

defs = {}
(Dir[File.join(opt[:root], "*.rb")].sort + Dir[File.join(opt[:fixture], "*.rb")].sort).each do |f|
  lines = File.readlines(f)
  i = 0
  while i < lines.size
    if lines[i] =~ /\Adef ([a-z_0-9]+)\(/
      name = Regexp.last_match(1)
      j = i
      j += 1 until lines[j].nil? || lines[j] =~ /\Aend\b/
      defs[name] = lines[i..j].join
      i = j
    end
    i += 1
  end
end

pairs = File.readlines(File.join(ROOT, "tests/doom-core/fixtures/source/dups.tsv"))
            .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split }
bad = 0
pairs.each do |orig, copy, renames|
  a = defs[orig]
  b = defs[copy]
  if a.nil? || b.nil?
    puts "  FAIL #{orig} / #{copy}: #{a.nil? ? orig : copy} is not defined under #{opt[:root]} or #{opt[:fixture]}"
    bad += 1
    next
  end
  # A copy may call other copies: the third column names them, `original=copy`,
  # and each is read back as its original before the bodies are compared.
  b = b.sub(/\Adef #{Regexp.escape(copy)}\(/, "def #{orig}(")
  renames.to_s.split(",").each do |r|
    from, to = r.split("=", 2)
    b = b.gsub(/\b#{Regexp.escape(to)}\b/, from)
  end
  if b == a
    puts "  pass #{copy} is #{orig}, renamed"
  else
    puts "  FAIL #{copy} has drifted from #{orig}"
    bad += 1
  end
end
puts "dup-check: #{pairs.size} pair(s), #{bad} failing"
exit(bad.zero? ? 0 : 1)
