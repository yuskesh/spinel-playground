# frozen_string_literal: true
#
# The original Full helper, answering for itself.
#
# Decision 0007 task 5 asks for the extracted helpers to be compared with the
# original Full/CRuby ones. So the expectations are not written down anywhere:
# this loads `examples/doom/lib/doom/fixed.rb` UNMODIFIED and asks it, and it
# also loads the extracted sources and asks them, so the adaptation is checked
# by agreement rather than by argument.
#
# Two questions, and they are separate:
#
#   1. does the EXTRACTED Ruby still answer what the ORIGINAL Ruby answers?
#      That is what makes an adaptation a spelling change rather than a
#      semantic one, and it is settled here, before any compiler is involved.
#   2. does the CORE kernel answer the same? That is the runner's job, against
#      the values this prints.
#
# usage: oracle.rb <repo-root>    -- prints "<id>\t<value>" per case

root = ARGV[0] or abort("oracle: the repository root is required")
fixtures = File.join(root, "tests", "core-boundary", "fixtures", "capabilities")

require File.join(root, "examples", "doom", "lib", "doom", "fixed")
Dir[File.join(fixtures, "src", "*.rb")].sort.each { |f| load f }

ORIGINAL = {
  "fixed_to_i32" => ->(v) { Doom::Fixed.to_i32(v) },
  "fixed_mul" => ->(a, b) { Doom::Fixed.mul(a, b) },
  "fixed_cdiv" => ->(n, d) { Doom::Fixed.cdiv(n, d) },
  "fixed_div" => ->(a, b) { Doom::Fixed.div(a, b) },
  "fixed_bam" => ->(v) { Doom::Fixed.bam(v) },
}.freeze

rows = File.readlines(File.join(fixtures, "cases.tsv"), chomp: true)
           .reject { |l| l.start_with?("#") || l.strip.empty? }
           .map { |l| l.split("\t", -1) }
abort("oracle: cases.tsv holds no cases") if rows.empty?

# Every extracted helper must be exercised, or the table would look complete
# while covering fewer.
on_disk = Dir[File.join(fixtures, "src", "*.rb")].map { |f| File.basename(f, ".rb") }.sort
named = rows.map { |r| r[1] }.uniq.sort
if on_disk != named
  abort("oracle: src/ holds #{on_disk.inspect} and the table names #{named.inspect}")
end

failures = 0
rows.each do |id, helper, args|
  values = args.split(",").map { |s| Integer(s, 10) }
  original = ORIGINAL.fetch(helper).call(*values)
  extracted = send(helper, *values)
  if original != extracted
    warn("MISMATCH #{id}: the original says #{original}, the extraction says #{extracted}")
    failures += 1
    next
  end
  puts("#{id}\t#{original}")
end
warn("oracle: #{rows.length} case(s), #{failures} adaptation mismatch(es)")
exit(failures.zero? ? 0 : 1)
