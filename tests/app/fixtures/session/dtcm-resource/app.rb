# dtcm-resource: renderer_colormap is a resource of the session, read in place
# from the NOR; only a writable field can be kept in the data TCM, so step 1
# refuses the declaration.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries", dtcm: ["renderer_colormap"]
state :n, :i64, 1
every_ms 10, :tic

def tic(n)
  n[0] = DoomCore.step(0)
  0
end
