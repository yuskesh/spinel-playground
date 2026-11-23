# dtcm-none: dtcm-screen without the keyword; the screen stays in the
# session's writable part.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries"
state :n, :i64, 1
every_ms 10, :tic

def tic(n)
  n[0] = DoomCore.step(0)
  0
end
