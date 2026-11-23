# frozen_string_literal: true
#
# The language oracle for tests/core-boundary/arithmetic.sh.
#
# Decision 0007 fixes the successful arithmetic to Ruby's: floor division,
# divisor-signed remainder, arithmetic right shift, and mathematical integers
# admitted only where the result lands inside the declared domain.  So the
# reference for a successful case is CRuby running the SAME definition the
# boundary will compile -- not a second table written by the same hand as the
# first.
#
# This program checks three things and executes nothing from the compiler:
#
#   1. the case table is well formed and in bijection with the fixtures;
#   2. CRuby's value for each case agrees with the table's declared value;
#   3. the table's declared status and reason agree with the domain rule
#      applied to CRuby's result -- derived here, independently of what the
#      case claims.
#
# A case whose claim and derivation disagree FAILS.  It is not silently
# replaced by the derived value: the table is a claim written from the decision
# record, and a disagreement means one of the two is wrong.


# `filter_map` and `tally` are 2.7. Checked rather than discovered as a
# NoMethodError halfway through: a Ruby too old to run this exits non-zero for
# its own reason, and a caller that reads only the exit status cannot tell that
# apart from a refusal it asked for.
MIN_RUBY = "2.7.0"
if Gem::Version.new(RUBY_VERSION) < Gem::Version.new(MIN_RUBY)
  abort("oracle: ruby #{RUBY_VERSION} is too old; this needs #{MIN_RUBY} or later " \
        "(set RUBY=/path/to/ruby)")
end

FIX = File.join(__dir__, "fixtures", "arithmetic")
SRC = File.join(FIX, "src")

DOMAIN = {
  "i64" => (-(2**63)..(2**63 - 1)),
  "i32" => (-(2**31)..(2**31 - 1)),
  "u32" => (0..(2**32 - 1)),
}.freeze

# The reasons a checked run can give, and the status each lands in. The first
# three are the machine's; the last three are `core_fail` naming a status
# outright, which is why they map to themselves.
#
# `shift-range` is decision 0007's count rule, which decision 0042's S1
# replaced: no shift derives it now. It stays a known reason so that a table
# planting it (the "0007 count rule" mutation control) is a wrong answer the
# domain rule refutes, not a malformed row.
STATUS_OF = {
  "div-zero" => "arithmetic",
  "shift-range" => "arithmetic",
  "overflow" => "arithmetic",
  "negative-exponent" => "arithmetic",
  "argument" => "argument",
  "bounds" => "bounds",
  "capacity" => "capacity",
}.freeze
REASONS = STATUS_OF.keys.freeze


# ---- the checked evaluator ------------------------------------------------
#
# A domain check applied to the FINAL value cannot see an expression that
# leaves i64 and comes back: `(INT64_MAX + 1) - 1` is INT64_MAX in Ruby, and
# the boundary must still refuse it. So the status is derived by running the
# SAME definitions again with operands that check each operation as it happens.
#
# This is Ruby's own dispatch doing the walking, not a second interpreter: the
# method bodies are untouched, and `coerce` puts plain literals and loop
# counters on the same footing. The plain run stays, and the two values are
# required to agree wherever the checked run succeeds -- if this wrapper ever
# computed something different from Integer, that disagreement is the failure.
# `core_fail(:<category>)` names one of the boundary's own failure statuses.
# The oracle has to have it too, because it runs the same source.
def core_fail(category)
  raise Checked::Failure, category.to_s
end

class Checked
  I64 = (-(2**63)..(2**63 - 1))

  class Failure < StandardError
    attr_reader :reason
    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end

  attr_reader :v

  def initialize(value)
    @v = value
  end

  def self.of(x)
    x.is_a?(Checked) ? x : Checked.new(x)
  end

  # What makes `0 + checked` and `plain < checked` work without touching the
  # method bodies: Integer hands the pair back to us.
  def coerce(other)
    [Checked.new(other), self]
  end

  def fits(r)
    raise Failure, "overflow" unless I64.cover?(r)
    Checked.new(r)
  end
  private :fits

  def +(o)
    fits(@v + Checked.of(o).v)
  end
  def -(o)
    fits(@v - Checked.of(o).v)
  end
  def *(o)
    fits(@v * Checked.of(o).v)
  end
  def -@
    fits(-@v)
  end
  def +@
    self
  end
  def ~
    fits(~@v)
  end
  def abs
    fits(@v.abs)
  end

  # Decision 0042 stage 3: the exact power, failing past the width; a
  # negative exponent fails on its own, where Ruby's answer is a Rational.
  # An exponent of 64 or more fits only for a base of -1, 0 or 1, so it is
  # decided before Ruby builds a large Bignum.
  def **(o)
    e = Checked.of(o).v
    raise Failure, "negative-exponent" if e.negative?
    raise Failure, "overflow" if e >= 64 && @v.abs > 1
    fits(@v**(e >= 64 ? 2 + e % 2 : e))
  end

  def /(o)
    d = Checked.of(o).v
    raise Failure, "div-zero" if d.zero?
    fits(@v / d)
  end

  def %(o)
    d = Checked.of(o).v
    raise Failure, "div-zero" if d.zero?
    fits(@v % d)
  end

  # Decision 0042, S1: Ruby's rule wherever the value fits. A negative count
  # shifts the other way, so `a >> n` is `a << -n`; a right shift by 64 or
  # more is the sign fill; a left shift is checked as any other result, and
  # one by 64 or more of a non-zero value is past the width. The count is
  # bounded before Ruby shifts, so a large count builds no large Bignum.
  def <<(o)
    shift_left(Checked.of(o).v)
  end

  def >>(o)
    shift_left(-Checked.of(o).v)
  end

  def shift_left(c)
    return fits(@v >> [-c, 64].min) if c.negative?
    return fits(0) if @v.zero?
    raise Failure, "overflow" if c >= 64
    fits(@v << c)
  end
  private :shift_left

  def &(o)
    fits(@v & Checked.of(o).v)
  end
  def |(o)
    fits(@v | Checked.of(o).v)
  end
  def ^(o)
    fits(@v ^ Checked.of(o).v)
  end

  def <(o)
    @v < Checked.of(o).v
  end
  def <=(o)
    @v <= Checked.of(o).v
  end
  def >(o)
    @v > Checked.of(o).v
  end
  def >=(o)
    @v >= Checked.of(o).v
  end
  def ==(o)
    @v == Checked.of(o).v
  end
  def !=(o)
    @v != Checked.of(o).v
  end

  def to_s
    @v.to_s
  end
  def inspect
    "Checked(#{@v})"
  end
end

$pass = 0
$fail = 0

def ok(msg)
  puts "  pass #{msg}"
  $pass += 1
end

def bad(msg)
  puts "  FAIL #{msg}"
  $fail += 1
end

# ---- the table ------------------------------------------------------------

rows = []
File.readlines(File.join(FIX, "cases.tsv"), chomp: true).each_with_index do |line, i|
  next if line.start_with?("#") || line.strip.empty?

  f = line.split("\t", -1)
  unless f.length == 9
    bad("cases.tsv line #{i + 1} has #{f.length} fields, not 9")
    next
  end
  rows << {
    line: i + 1, id: f[0], source: f[1], entry: f[2], op: f[3], result: f[4],
    args: f[5], status: f[6], value: f[7], reason: f[8],
  }
end

abort("oracle: cases.tsv holds no cases") if rows.empty?

puts "== the case table is well formed =="

dupes = rows.map { |r| r[:id] }.tally.select { |_, n| n > 1 }.keys
if dupes.empty?
  ok("#{rows.length} case ids, all distinct")
else
  bad("duplicate case id(s): #{dupes.join(', ')}")
end

unknown_result = rows.reject { |r| DOMAIN.key?(r[:result]) }
if unknown_result.empty?
  ok("every case declares a known result domain")
else
  bad("unknown result domain(s): #{unknown_result.map { |r| "#{r[:id]}:#{r[:result]}" }.join(', ')}")
end

shape_bad = rows.reject do |r|
  case r[:status]
  when "ok"      then r[:value] != "-" && r[:reason] == "-"
  when "refused" then r[:value] == "-" && r[:reason] != "-"
  when *STATUS_OF.values.uniq
    r[:value] == "-" && STATUS_OF[r[:reason]] == r[:status]
  else false
  end
end
if shape_bad.empty?
  ok("every case's value/reason columns match its status")
else
  bad("value/reason do not match status: #{shape_bad.map { |r| r[:id] }.join(', ')}")
end

unknown_status = rows.reject { |r| (["ok", "refused"] + STATUS_OF.values).include?(r[:status]) }
bad("unknown status(es): #{unknown_status.map { |r| "#{r[:id]}:#{r[:status]}" }.join(', ')}") unless unknown_status.empty?
ok("every case declares a known status") if unknown_status.empty?

# Bijection between the table and the fixture sources: nothing on disk goes
# unexercised, and nothing in the table names a file or a method that is not
# there.  The `def` scan is a test reading its own fixtures; the compiler side
# resolves entries through the analysed AST and never does this.
on_disk = Dir.children(SRC).select { |n| n.end_with?(".rb") }.sort
named = rows.map { |r| r[:source] }.uniq.sort
if on_disk == named
  ok("the table names exactly the #{on_disk.length} source file(s) in src/")
else
  bad("src/ holds #{on_disk.inspect} but the table names #{named.inspect}")
end

defs = {}
on_disk.each do |name|
  defs[name] = File.readlines(File.join(SRC, name), chomp: true)
                   .filter_map { |l| l[/\A def \s+ ([A-Za-z_][A-Za-z0-9_]*) /x, 1] }
                   .sort
end
# One definition per file, named after the file. The eligibility checker admits
# a top-level evidence call only into the closure of the root it is checking, so
# a second entry in one file would make its own evidence call an unadmitted
# top-level statement -- and the shape is worth pinning rather than rediscovering.
defs.each do |name, have|
  stem = File.basename(name, ".rb")
  want = rows.select { |r| r[:source] == name }.map { |r| r[:entry] }.uniq.sort
  helpers = have - [stem]
  text = File.read(File.join(SRC, name))
  # A helper is in the entry's closure and gets its evidence from the call site
  # inside; it is not an entry and the table does not name it. An UNCALLED
  # definition is neither, so it would sit in the fixture unexercised -- hence
  # the call check, which is a test reading its own fixtures and not something
  # the compiler does.
  uncalled = helpers.reject { |h| text.match?(/(?<!def )\b#{Regexp.escape(h)}\s*\(/) }
  if !have.include?(stem)
    bad("#{name} defines #{have.inspect} but none of them is #{stem}, its own name")
  elsif want != [stem]
    bad("#{name}: the table exercises #{want.inspect}; the entry is #{stem.inspect}")
  elsif !uncalled.empty?
    bad("#{name} defines #{uncalled.inspect}, which nothing in the file calls")
  elsif helpers.empty?
    ok("#{name}: one definition, named after the file, and the table exercises it")
  else
    ok("#{name}: entry #{stem} plus helper(s) #{helpers.inspect}, each called in the file")
  end
end

# ---- the oracle -----------------------------------------------------------

on_disk.each { |name| load File.join(SRC, name) }

puts "== CRuby agrees with the declared values, and the domain rule with the declared status =="

rows.each do |r|
  if r[:status] == "refused"
    # There is nothing for a language oracle to say about a form the boundary
    # refuses to compile: CRuby evaluates it happily.  The refusal is checked
    # by the toolchain lane, against the declared diagnostic category.
    ok("#{r[:id]} is a compile-time refusal (#{r[:reason]}); no value is claimed")
    next
  end

  args = r[:args].split(",").map { |s| Integer(s, 10) }
  outside = args.reject { |a| DOMAIN["i64"].cover?(a) }
  unless outside.empty?
    bad("#{r[:id]} passes #{outside.inspect}, which is outside the i64 entry domain")
    next
  end

  # A case naming a method the fixtures do not define is a case-level failure,
  # not a crash. The bijection check above already reports it; without this the
  # walk raised NoMethodError, the run ended early, and every LATER case went
  # unexamined while the runner saw only a non-zero exit.
  unless respond_to?(r[:entry], true)
    bad("#{r[:id]} names '#{r[:entry]}', which no fixture defines")
    next
  end

  # The plain run: CRuby's own answer for this expression, and the reference
  # for every successful value.
  plain = nil
  plain_raised = nil
  begin
    plain = send(r[:entry], *args)
  rescue ZeroDivisionError
    plain_raised = "div-zero"
  rescue Checked::Failure => e
    # `core_fail` raises in the plain run too: it is a statement about the
    # boundary, not about the arithmetic, so it fires whatever the operands are.
    plain_raised = e.reason
  end

  # The checked run: the same definitions, with every operation checked as it
  # happens. This is what derives the status.
  checked = nil
  derived = []
  begin
    out = send(r[:entry], *args.map { |a| Checked.new(a) })
    checked = out.is_a?(Checked) ? out.v : out
  rescue Checked::Failure => e
    derived << e.reason
  end

  if derived.empty? && !DOMAIN[r[:result]].cover?(checked)
    derived << "overflow"
  end

  # The two runs must agree wherever both produced a value. A wrapper that
  # computed something Integer would not is a broken oracle, and this is where
  # that shows up rather than as a mysteriously wrong expectation.
  if derived.empty? && plain_raised.nil? && plain != checked
    bad("#{r[:id]}: the plain run says #{plain} and the checked run says #{checked}; " \
        "the oracle disagrees with itself")
    next
  end
  if derived.include?("div-zero") && plain_raised != "div-zero"
    bad("#{r[:id]}: the checked run divided by zero and the plain run did not")
    next
  end
  # A `core_fail` fires on both runs or neither: it does not depend on whether
  # an operation overflowed, so a difference here means the two runs took
  # different branches.
  core_fail_reasons = %w[argument bounds capacity]
  if (derived & core_fail_reasons) != ([plain_raised].compact & core_fail_reasons)
    bad("#{r[:id]}: core_fail fired on one run and not the other " \
        "(checked: #{derived.inspect}, plain: #{plain_raised.inspect})")
    next
  end

  derived_status = derived.empty? ? "ok" : STATUS_OF.fetch(derived.first)
  value = checked

  if derived_status != r[:status]
    bad("#{r[:id]}: the table says #{r[:status]}, the checked evaluation derives " \
        "#{derived_status} (value: #{checked.inspect}, reasons: #{derived.inspect})")
    next
  end

  if r[:status] == "ok"
    want = Integer(r[:value], 10)
    if value == want
      ok("#{r[:id]} = #{value} (CRuby, #{r[:result]})")
    else
      bad("#{r[:id]}: the table says #{want}, CRuby says #{value}")
    end
  else
    if derived.include?(r[:reason])
      extra = derived - [r[:reason]]
      note = extra.empty? ? "" : " (also #{extra.join(', ')})"
      ok("#{r[:id]} is #{r[:status]} (#{r[:reason]})#{note}; unchecked CRuby would " \
         "have said #{plain_raised || plain}")
    else
      bad("#{r[:id]}: the table blames #{r[:reason]}, the domain rule derives #{derived.inspect}")
    end
  end
end

puts "oracle: #{$pass + $fail} checked, #{$pass} pass, #{$fail} fail"
exit($fail.zero? ? 0 : 1)
