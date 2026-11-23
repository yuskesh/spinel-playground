# decl-unknown-bound: `bound: "iterations unknown ..."` (decision 0021) is
# admitted only for the DoomCore members a core_session generates. An
# application's own core_extern declaring it is refused -- even in a module it
# names DoomCore, so the name alone admits nothing.
require "spinel/core"
state :a, :i32, 1
every_ms 5, :poll
module DoomCore
  core_extern :step, params: {predraws: :i64}, returns: :i32, isr_ok: false,
              bound: "iterations unknown \"the step has loops without a derived bound\"", provider: "drivers/step.c"
end
def poll(a)
  a[0] = DoomCore.step(0)
  0
end
