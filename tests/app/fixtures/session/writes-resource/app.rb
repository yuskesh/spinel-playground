# writes-resource: a resource of the session is read-only (decision 0021).
# renderer_jobmode is one; the entry stores into it, its kernel report says
# so, and the build refuses it at step 7.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries"
state :n, :i64, 1
every_ms 10, :tic

def tic(renderer_jobmode, n)
  renderer_jobmode[0] = 1
  n[0] = DoomCore.step(0)
  0
end
