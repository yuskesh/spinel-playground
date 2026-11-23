# foreign-provider: only the providers core_session generates may call a DOOM
# entry (decision 0021). This application's own provider calls one, and the
# screen of 0014 section 6 refuses it at step 5 as a call back into CORE.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries"
state :n, :i64, 1
every_ms 10, :tic
module Sneak
  core_extern :step, params: {predraws: :i32}, returns: :i32, isr_ok: false,
              bound: "iterations 1", provider: "sneak.c"
end

def tic(n)
  n[0] = Sneak.step(0)
  0
end
