# frozen_string_literal: true
#
# tools/doom/core-widths.rb — decision 0018's width table: the element type of
# every buffer DOOM's three CORE entries take, and the evidence that chooses it.
#
#   ruby tools/doom/core-widths.rb --stores FILE --ranges FILE,... --store-ranges DIR \
#        --measured-at COMMIT --output examples/doom/core/widths.tsv
#   ruby tools/doom/core-widths.rb --stores FILE --ranges FILE,... --store-ranges DIR \
#        --check examples/doom/core/widths.tsv
#
# --stores is tools/doom/core-store-widths.rb's output; --ranges are
# tools/doom/core-ranges.rb's, one per demo (the state after every tic and
# Full's writes); --store-ranges is a directory of tools/doom/core-store-ranges.rb's,
# every value the entries store in each port run tests/doom-core/verify.sh makes.
# The table has one row per buffer of
# examples/doom/core/entries/fields.tsv, without core_state (whose scalar slots
# 0018 keeps i64) and the derived index tables: field, element, min, max,
# evidence, measured_at.
#
# THE RULE (0018). A buffer whose stores bound it statically gets that bound --
# the union of its stores' ranges, `static:` with every store's file and line
# -- provided everything measured lies inside it, which is what puts the value
# Full prepares before the first tic inside it too. Every other buffer gets the
# union of the measured ranges, `observed:` with the demos, `+open` for the
# state before the first tic and `+stores:` with the port runs whose stores
# were recorded (0018: the values after each tic and every value stored). The element is the smallest of u8, i8, u16, i16,
# u32, i32 and i64 that holds min..max; a one-byte and a two-byte type are both
# tried unsigned first. Every buffer is a row, whatever its element is now,
# because 0018 gives each resident buffer of the entries its smallest type and
# a u8 or i32 buffer is measured the same way.
#
# --check is the re-measurement 0018 requires. It fails a row when a measured
# value lies outside the row's element (not outside its min..max: the element
# is what a store narrows to), when a static row's stores no longer bound the
# field or bound it more widely than the row says, when the table and the
# entries name different buffers, and when a row is malformed. A failure is not
# fixed by editing the row: the table is regenerated from a new measurement.
#
# REPRESENTATIONS (decision 0022 section 2.4). examples/doom/core/widths-repr.tsv
# names the buffers whose element is a representation rather than the
# smallest type of their range. For `i32-bits` the measured values must fit
# 32 bits read one way, all within u32 or all within i32 (the cell holds the
# word's signed bit pattern), and the element is i32; anything else is
# refused. The row keeps its measured min and max and its evidence ends with
# `;i32-bits:BASIS`. --check holds such a row to the same 32-bit test.

require "optparse"

ROOT = File.expand_path("../..", __dir__)
TYPES = [["u8", 0, 255], ["i8", -128, 127], ["u16", 0, 65_535], ["i16", -32_768, 32_767],
         ["u32", 0, 4_294_967_295], ["i32", -2_147_483_648, 2_147_483_647],
         ["i64", -(1 << 63), (1 << 63) - 1]].freeze
RANGE = TYPES.to_h { |t, lo, hi| [t, [lo, hi]] }.freeze
HEADER = "#field\telement\tmin\tmax\tevidence\tmeasured_at"

opt = {}
OptionParser.new do |o|
  o.on("--stores FILE") { |v| opt[:stores] = v }
  o.on("--ranges LIST") { |v| opt[:ranges] = v.split(",") }
  o.on("--store-ranges DIR") { |v| opt[:store_ranges] = v }
  o.on("--measured-at COMMIT") { |v| opt[:at] = v }
  o.on("--output FILE") { |v| opt[:output] = v }
  o.on("--check FILE") { |v| opt[:check] = v }
end.parse!
opt[:stores] && opt[:ranges] && opt[:store_ranges] && (opt[:check] || (opt[:output] && opt[:at])) or
  abort("usage: core-widths.rb --stores FILE --ranges FILE,... --store-ranges DIR (--measured-at COMMIT --output FILE | --check FILE)")

def rows(path)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
end

def smallest(mn, mx) = TYPES.find { |_, lo, hi| mn >= lo && mx <= hi }[0]

# an i32-bits buffer's range fits 32 bits read one way: unsigned or signed
def word32?(mn, mx) = [RANGE["u32"], RANGE["i32"]].any? { |lo, hi| lo <= mn && mx <= hi }

fields = rows(File.join(ROOT, "examples/doom/core/entries/fields.tsv"))
         .map { |r| r[2] }.reject { |f| f == "core_state" || f.start_with?("derived:") }.uniq.sort

repr = {}
rows(File.join(ROOT, "examples/doom/core/widths-repr.tsv")).each do |f, kind, basis|
  kind == "i32-bits" or abort("core-widths: widths-repr.tsv: #{f}: representation #{kind.inspect} is not i32-bits")
  fields.include?(f) or abort("core-widths: widths-repr.tsv: #{f} is not an entry buffer")
  repr[f] = basis
end

stores = {}
rows(opt[:stores]).each do |f, _el, _n, *_c, static, mn, mx, sites|
  stores[f] = { static: static == "yes", range: static == "yes" ? [Integer(mn), Integer(mx)] : nil, sites: sites }
end

# The measured range of each buffer, over every demo given, and which demos.
demos = []
seen = Hash.new { |h, k| h[k] = [] }
opt[:ranges].each do |path|
  head = File.foreach(path).first.to_s
  demo = head[/core-ranges\.rb: (DEMO\d+)/, 1] or abort("core-widths: #{path} is not core-ranges.rb output")
  demos << demo
  rows(path).each do |f, _role, _el, _count, mn, mx, *|
    next if mn == "-"
    seen[f] << [Integer(mn), Integer(mx)]
  end
end
# Every value stored, over every recorded port run.
runs = []
Dir[File.join(opt[:store_ranges], "*.tsv")].sort.each do |path|
  head = File.foreach(path).first.to_s
  run = head[/core-store-ranges\.rb: (\S+)/, 1] or abort("core-widths: #{path} is not core-store-ranges.rb output")
  runs << run
  rows(path).each { |f, _entry, _n, mn, mx| seen[f] << [Integer(mn), Integer(mx)] }
end
runs.empty? and abort("core-widths: no core-store-ranges.rb output in #{opt[:store_ranges]}")
measured = seen.transform_values { |l| [l.map(&:first).min, l.map(&:last).max] }
# The runs, by kind: input, step-DEMO1, render-scaled, scenario-punch ...
kinds = runs.group_by { |r| r.split("-").first }.map { |k, l| l.size == 1 ? k : "#{k}:#{l.size}" }
observed_label = "observed:#{demos.join(',')}+open+stores:#{kinds.join(',')}"

if opt[:output]
  missing = fields.reject { |f| measured.key?(f) }
  missing.empty? or abort("core-widths: no measurement of #{missing.join(', ')}")
  out = fields.map do |f|
    mn, mx = measured.fetch(f)
    s = stores[f]
    row = if s && s[:static] && s[:range][0] <= mn && mx <= s[:range][1]
      lo, hi = s[:range]
      [f, smallest(lo, hi), lo, hi, "static:#{s[:sites]}", opt[:at]]
    else
      [f, smallest(mn, mx), mn, mx, observed_label, opt[:at]]
    end
    next row unless repr.key?(f)
    word32?(row[2], row[3]) or abort("core-widths: #{f} is i32-bits, and #{row[2]}..#{row[3]} does not fit 32 bits")
    [f, "i32", row[2], row[3], "#{row[4]};i32-bits:#{repr[f]}", opt[:at]]
  end
  File.open(opt[:output], "w") do |io|
    io.puts "# examples/doom/core/widths.tsv -- GENERATED by tools/doom/core-widths.rb; do not edit."
    io.puts "#"
    io.puts "# Decision 0018: the element type of every buffer the three CORE entries take, and its"
    io.puts "# evidence. `static:` lists every store to the field (tools/doom/core-store-widths.rb), all"
    io.puts "# of which bound it; `observed:` is the union of the ranges tools/doom/core-ranges.rb read"
    io.puts "# after every tic of those demos and before the first, and of every value the entries stored"
    io.puts "# in the port runs tools/doom/core-store-ranges.rb recorded. Observed ranges are evidence, not"
    io.puts "# proof: a store outside the element fails the entry with ARITHMETIC. A row whose evidence"
    io.puts "# ends with `;i32-bits:` holds a 32-bit word as its signed bit pattern, its element i32"
    io.puts "# (examples/doom/core/widths-repr.tsv, decision 0022 section 2.4). Regenerated, never"
    io.puts "# edited, when tests/doom-core/widths.sh finds a value outside a row's element."
    io.puts HEADER
    out.each { |r| io.puts r.join("\t") }
  end
  n = out.group_by { |r| r[4].start_with?("static:") ? "static" : "observed" }.transform_values(&:size)
  puts "core-widths: #{out.size} row(s), #{n['static'] || 0} static, #{n['observed'] || 0} observed -> #{opt[:output]}"
  out.group_by { |r| r[1] }.sort_by { |t, _| TYPES.index { |x| x[0] == t } }
     .each { |t, l| puts "  #{t}: #{l.size}" }
  exit 0
end

# --check
pass = 0
fail = 0
bad = ->(msg) { puts "  FAIL #{msg}"; fail += 1 }
lines = File.readlines(opt[:check])
lines.include?("#{HEADER}\n") or bad.("#{opt[:check]} has no header `#{HEADER.tr("\t", ' ')}`")
table = {}
rows(opt[:check]).each do |r|
  unless r.length == 6
    bad.("a row of #{r.length} column(s), want 6: #{r.join(' ')}")
    next
  end
  f, el, mn, mx, ev, _at = r
  bad.("#{f} is listed twice") if table.key?(f)
  table[f] = { el: el, min: mn, max: mx, ev: ev }
end
(fields - table.keys).each { |f| bad.("#{f}: an entry buffer the table has no row for") }
(table.keys - fields).each { |f| bad.("#{f}: a row for a buffer no entry takes") }
table.each do |f, t|
  next unless fields.include?(f)
  unless RANGE.key?(t[:el])
    bad.("#{f}: element #{t[:el].inspect} is not one of #{TYPES.map(&:first).join(', ')}")
    next
  end
  lo, hi = RANGE[t[:el]]
  if repr.key?(f) || t[:ev].include?(";i32-bits:")
    bits = "#{f}: i32-bits in #{repr.key?(f) ? 'widths-repr.tsv' : 'the row'} and not in #{repr.key?(f) ? 'the row' : 'widths-repr.tsv'}"
    next bad.(bits) unless repr.key?(f) && t[:ev].end_with?(";i32-bits:#{repr[f]}")
    next bad.("#{f}: i32-bits with element #{t[:el]}, want i32") unless t[:el] == "i32"
    # the word's two readings together: what an i32-bits cell may hold
    lo, hi = RANGE["i32"][0], RANGE["u32"][1]
    m = measured[f]
    next bad.("#{f}: measured #{m[0]}..#{m[1]}, which does not fit 32 bits read one way") if m && !word32?(*m)
  end
  mn = Integer(t[:min], exception: false)
  mx = Integer(t[:max], exception: false)
  unless mn && mx && mn <= mx && lo <= mn && mx <= hi
    bad.("#{f}: min..max #{t[:min]}..#{t[:max]} is not inside #{t[:el]}")
    next
  end
  m = measured[f]
  if m.nil?
    bad.("#{f}: not measured by #{demos.join(', ')}")
    next
  end
  if m[0] < lo || m[1] > hi
    bad.("#{f}: measured #{m[0]}..#{m[1]}, outside its element #{t[:el]} (#{lo}..#{hi})")
    next
  end
  if t[:ev].start_with?("static:")
    s = stores[f]
    unless s && s[:static]
      bad.("#{f}: the row is static, and its stores no longer bound it")
      next
    end
    unless lo <= s[:range][0] && s[:range][1] <= hi
      bad.("#{f}: its stores now reach #{s[:range][0]}..#{s[:range][1]}, outside its element #{t[:el]}")
      next
    end
  elsif !t[:ev].start_with?("observed:")
    bad.("#{f}: evidence #{t[:ev].inspect} is neither static: nor observed:")
    next
  end
  pass += 1
end
puts "core-widths: #{pass + fail} checked, #{pass} pass, #{fail} fail (#{demos.join(', ')} and #{runs.size} recorded run(s) against #{opt[:check]})"
exit(fail.zero? ? 0 : 1)
