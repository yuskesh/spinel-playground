# tests/doom-core/harness/pins.rb — the frame lane's pinned strings, extracted.
#
#   ruby tests/doom-core/harness/pins.rb [--revision REV] [--out FILE]
#
# The 0009 stage 1 expectations must assert, for every key an old tick.sh pin
# asserted, the value that pin asserted -- taken mechanically, never retyped and
# never taken from a new run of the port. This is the mechanical step: it reads
# tick.sh at the FROZEN revision, finds the frame-lane checks, and prints each
# one's expected string with the case it belongs to.
#
# IT READS THE REVISION, NOT THE WORKING TREE. The pins come out of tick.sh as
# stage 1 ends, so a working-tree read would quietly start returning fewer and
# fewer pins as the migration proceeds -- and would return none at all once the
# migration is done, which is exactly when the expectations must still be
# traceable to what they replaced. The revision and the blob it read are printed
# in the output, and a revision this checkout does not have is an error, not a
# fallback: a shallow clone must fail loudly rather than extract from whatever
# tick.sh happens to be on disk.
#
# THE FRAME-LANE CHECKS are the `ok` calls whose compared text comes from one of
# the lane's run helpers. Each helper both prints its run's output and keeps it
# in a file named after the run, and the checks use both: some call the helper
# inside the substitution, some read the file a previous call wrote.
#
#   sp  MODE TICS CONTROL           ruby      -> sp-MODE-CONTROL.out, read by spo
#   spn LIB TAG MODE TICS CONTROL   compiled  -> spn-TAG-MODE-CONTROL.out
#   sps TAG MODE TICS FIELDS        session   -> sps-TAG-MODE.out
#   spf TICS CONTROL                session   -> spf-CONTROL.out
#   spa TAG MODE TICS CONTROL       adapter   -> spa-TAG-MODE.out
#
# So the run table is built first, from every helper CALL in the script, keyed
# by the file that call writes; a check then names its run either by calling the
# helper again or by reading that file. A check whose run is not in the table is
# an error rather than a skipped row: it would silently drop a pin.
#
# A pin whose text is piped through `fctl` is marked filtered: that check
# asserts a SUBSET of the report, and a consumer that forgets it would read the
# dropped lines as absent rather than as not asserted.

require "open3"

REVISION = "e2f5676"  # the stage 1 freeze; the frame-lane pins are identical through 2a7f479
TICK = "tests/doom-core/tick.sh"

# For each helper: the route, the run it describes read out of its arguments as
# [mode, frames, control], and the name of the file that call writes.
HELPERS = {
  "sp"  => ["ruby",     ->(a) { [a[0], a[1], a[2]] },          ->(a) { "sp-#{a[0]}-#{a[2]}" }],
  "spn" => ["compiled", ->(a) { [a[2], a[3], a[4]] },          ->(a) { "spn-#{a[1]}-#{a[2]}-#{a[4]}" }],
  "sps" => ["session",  ->(a) { [a[1], a[2], "none"] },        ->(a) { "sps-#{a[0]}-#{a[1]}" }],
  "spf" => ["session",  ->(a) { ["frame", a[0], a[1]] },       ->(a) { "spf-#{a[1]}" }],
  "spa" => ["adapter",  ->(a) { [a[1], a[2], a[3]] },          ->(a) { "spa-#{a[0]}-#{a[1]}" }]
}.freeze

def git(*args)
  out, err, status = Open3.capture3("git", *args)
  status.success? or abort("pins.rb: git #{args.join(' ')} failed: #{err.strip}")
  out
end

# A shell word list: quotes are removed, a $(...) keeps its text so the helper
# call inside it can be read, and a comment or a `;` ends the statement.
def tokenize(s) # rubocop:disable Metrics/MethodLength
  args = []
  i = 0
  while i < s.size
    i += 1 while i < s.size && s[i] =~ /\s/
    break if i >= s.size || s[i] == ";" || s[i] == "#"
    tok = +""
    while i < s.size && s[i] !~ /[\s;]/
      case s[i]
      when '"'
        i += 1
        until i >= s.size || s[i] == '"'
          if s[i] == "\\"
            tok << s[i, 2]
            i += 2
          elsif s[i, 2] == "$("
            inner, i = command_substitution(s, i)
            tok << inner
          else
            tok << s[i]
            i += 1
          end
        end
        i += 1
      when "'"
        j = s.index("'", i + 1) || s.size
        tok << s[(i + 1)...j]
        i = j + 1
      else
        tok << s[i]
        i += 1
      end
    end
    args << tok
  end
  args
end

# From "$(" to its matching ")", quotes inside kept as they are.
def command_substitution(s, i)
  out = +"$("
  i += 2
  depth = 1
  while i < s.size && depth.positive?
    c = s[i]
    if c == "'" || c == '"'
      j = i + 1
      j += (s[j] == "\\" ? 2 : 1) while j < s.size && s[j] != c
      out << s[i..j]
      i = j + 1
      next
    end
    depth += 1 if c == "("
    depth -= 1 if c == ")"
    break if depth.zero?
    out << c
    i += 1
  end
  [out + ")", i + 1]
end

# Backslash continuations joined; each statement keeps the line it started on.
def statements(text)
  out = []
  buf = nil
  start = nil
  text.lines.each_with_index do |raw, idx|
    line = raw.chomp
    if buf
      buf << " " << line.strip.sub(/\\\z/, "")
    else
      start = idx + 1
      buf = line.strip.sub(/\\\z/, "")
    end
    next if line.end_with?("\\")
    out << [start, buf]
    buf = nil
  end
  out << [start, buf] if buf
  out
end

# `for c in a b c; do BODY; done` becomes BODY once per word.
def expand(stmt)
  return [stmt] unless stmt =~ /\Afor (\w+) in (.+?); do (.+); done\z/
  var, list, body = $1, $2, $3
  list.split.map { |word| body.gsub("$#{var}", word) }
end

def unquote(word)
  word.delete('"').delete("'")
end

# Every helper CALL in the script, keyed by the file that call writes.
def runs(stmts)
  table = {}
  stmts.each do |_line, stmt|
    expand(stmt).each do |one|
      one.split(";").each do |part|
        a = tokenize(part.strip)
        route, read, names = HELPERS[a[0]]
        next unless route
        args = a[1..].map { |w| unquote(w) }
        key = names.call(args)
        # A call whose run cannot be named without expanding a shell variable --
        # the helper's own definition, say -- names no run.
        next if key.include?("$") || key.include?("nil")
        table[key] = [route] + read.call(args)
      end
    end
  end
  table
end

# EVERY run a check's compared text comes from, in the order it names them: a
# helper called inside the substitution, `spo` reading what `sp` wrote, or the
# file some other call wrote. A check may name more than one -- the composite
# refusal check joins four -- and then its expected string belongs to no single
# case; it is reported as a composite rather than attributed to the first.
def runs_of(got, table)
  found = []
  got.scan(/\$\((\w+) ([^|)]*)/) do |helper, rest|
    next unless HELPERS.key?(helper)
    args = rest.split.map { |w| unquote(w) }
    route, read, names = HELPERS[helper]
    found << [names.call(args), [route] + read.call(args)]
  end
  got.scan(/\$\(spo (\w+) ([\w.-]+)/) { |mode, control| k = "sp-#{mode}-#{control}"; found << [k, table[k]] }
  got.scan(%r{\$W/((?:sp|spn|sps|spf|spa)-[\w.-]+)\.out}) { |k,| found << [k, table[k]] }
  found
end

def main
  revision = REVISION
  out = nil
  args = ARGV.dup
  until args.empty?
    case (flag = args.shift)
    when "--revision" then revision = args.shift
    when "--out" then out = args.shift
    else abort("usage: pins.rb [--revision REV] [--out FILE]")
    end
    abort("pins.rb: #{flag} needs a value") if (flag == "--revision" && revision.nil?) || (flag == "--out" && out.nil?)
  end

  commit = git("rev-parse", "--verify", "#{revision}^{commit}").strip
  blob = git("rev-parse", "--verify", "#{revision}:#{TICK}").strip
  text = git("show", "#{revision}:#{TICK}")

  stmts = statements(text)
  table = runs(stmts)

  rows = []
  stmts.each do |line, stmt|
    a = tokenize(stmt)
    next unless a[0] == "ok" && a.length >= 4
    got, expected = a[2], a[3]
    found = runs_of(got, table)
    next if found.empty?
    found.each do |key, run|
      run or abort("pins.rb: #{TICK}:#{line} compares the run #{key}, which no helper call in the script writes")
    end
    text = got.include?("fctl") ? "filtered" : "whole"
    if found.length > 1
      # Named, not dropped: a consumer must split it into one case per run.
      next unless found.any? { |_, run| run[1] == "frame" }
      rows << ["composite", "composite", found.map(&:first).join(","), found.length.to_s, line, "composite", text, expected]
      next
    end
    key, (route, mode, frames, control) = found.first
    next unless mode == "frame"
    rows << [route, mode, control, frames, line, key, text, expected]
  end

  report = +""
  report << "# frame-lane pins of #{TICK}, extracted by tests/doom-core/harness/pins.rb\n"
  report << "# revision\t#{revision}\t#{commit}\n"
  report << "# blob\t#{blob}\n"
  report << "# pins\t#{rows.length}\n"
  report << ["#route", "mode", "control", "frames", "line", "run", "text", "expected"].join("\t") << "\n"
  rows.each { |r| report << r.join("\t") << "\n" }
  out ? File.write(out, report) : print(report)
  warn("pins.rb: #{rows.length} frame-lane pins at #{revision} (#{TICK} blob #{blob[0, 12]})")
end

main
