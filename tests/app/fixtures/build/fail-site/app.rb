# fail-site: a planted overflow for spinel-core-app --failure-sites. The
# product grows 7, 7007, 7007007, and the fourth release's 7007007 * 1000
# leaves i32: ARITHMETIC at the multiplication on line 9.
require "spinel/core"
state :acc, :i32, 1
every_ms 2, :step

def step(acc)
  acc[0] = acc[0] * 1000 + 7
  0
end
