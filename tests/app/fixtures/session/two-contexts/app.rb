# two-contexts: the session is written from one context (decision 0021). The
# thread entry calls DoomCore; the interrupt entry names a session state, so
# the session would be written from two contexts, and the build refuses it at
# step 7, naming both.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries"
state :n, :i64, 1
every_ms 10, :tic
every_us 1000, :poke, context: :interrupt

def tic(n)
  n[0] = DoomCore.step(0)
  0
end

def poke(core_command)
  core_command[4] = 0
  0
end
