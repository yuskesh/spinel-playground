# Two thread entries with the same period; the stimulus's `cost` lines drive
# the scheduling case (0014 §4), and the app itself only counts.
require "spinel/core"
state :a_runs, :u32, 1
state :b_runs, :u32, 1
every_us 1000, :a
every_us 1000, :b
def a(a_runs)
  a_runs[0] = a_runs[0] + 1
  0
end
def b(b_runs)
  b_runs[0] = b_runs[0] + 1
  0
end
