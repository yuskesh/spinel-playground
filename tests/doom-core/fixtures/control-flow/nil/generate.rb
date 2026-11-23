# tests/doom-core/fixtures/control-flow/nil/generate.rb
#
# THE NIL SWEEP. Mac review of 33da4d9 reported that a short-circuit nil path
# compiles to OK 0. Nine hand-picked shapes did not reproduce it, and picking
# shapes by hand is a poor way to answer the question -- so these are DERIVED
# FROM THE RULE instead.
#
# `Eligibility.cpp::markPositions` decides value position from statement
# position top-down: only the LAST element of a `StatementsNode` inherits
# value-consumption, a loop body never does, and a predicate always does. This
# crosses every nil-producing construct with every position that rule
# distinguishes, in the entry and in a helper.
#
# What tests/doom-core/control-flow.sh then requires: every VALUE position is
# refused with a diagnostic, and every STATEMENT position is admitted AND
# agrees with CRuby -- because admitting them is correct (nothing reads the
# value) and the thing actually worth checking is that the admitted ones are
# not quietly wrong.
#
# WHAT THIS SWEEP DOES NOT COVER, and a correction to what it was first
# reported as. It is exhaustive over ONE AXIS -- where a nil-producing
# construct sits -- because that is the axis the position rule defines. It has
# nothing to say about a second axis: whether a local's BINDING is reachable
# on the path that reads it. The defect Mac review actually reported lived
# there, and this sweep ran clean straight through it:
#
#     (flag != 0) && (t = buf[0]) > 0
#     t
#
# is not a nil-producing CONSTRUCT in any position; it is an ordinary read of
# a local that was never bound. See ../bind/ for that axis. Reporting "24
# shapes, none reproduce" as though it answered the question was the mistake;
# deriving shapes from a rule makes a sweep exhaustive over that rule and says
# nothing whatever about what the rule does not mention.
# Shapes derived from the position rule in Eligibility.cpp::markPositions,
# not guessed: a nil-producing construct in every position the rule
# distinguishes, in the entry and in a helper, value-consumed and not.
NIL_FORMS = {
  "noelse"   => "if flag != 0\n    buf[0] = 7\n  end",
  "retif"    => "return 7 if flag != 0",
  "whileval" => "i = 0\n  while i < flag\n    i = i + 1\n  end",
  "unless"   => "unless flag != 0\n    buf[0] = 7\n  end",
}
POSITIONS = {
  # name => [body of entry, extra defs]
  "entry-last"      => ->(f) { ["  #{f}\n", ""] },
  "entry-midstmt"   => ->(f) { ["  #{f}\n  buf[0]\n", ""] },
  "entry-inwhile"   => ->(f) { ["  j = 0\n  while j < 2\n    #{f.gsub("\n", "\n  ")}\n    j = j + 1\n  end\n  buf[0]\n", ""] },
  "helper-last"     => ->(f) { ["  h(buf, flag)\n", "def h(buf, flag)\n  #{f}\nend\n"] },
  "helper-midstmt"  => ->(f) { ["  h(buf, flag)\n", "def h(buf, flag)\n  #{f}\n  buf[0]\nend\n"] },
  "assigned"        => ->(f) { ["  x = begin\n    #{f.gsub("\n", "\n  ")}\n  end\n  x\n", ""] },
}
dir = ARGV[0]
POSITIONS.each do |pname, mk|
  NIL_FORMS.each do |fname, form|
    stem = "#{pname}_#{fname}".tr("-", "_")
    body, extra = mk.call(form)
    File.write(File.join(dir, "src", "#{stem}.rb"), "#{extra}def #{stem}(buf, n_buf, flag)\n#{body}end\n")
    File.write(File.join(dir, "src", "#{stem}.contract"), <<~C)
      core-contract 1
      root src/#{stem}.rb
      entry #{stem}
      result i64
      param buf buffer i64 inout count n_buf
      param n_buf scalar u64
      param flag scalar i64
    C
    puts stem
  end
end
