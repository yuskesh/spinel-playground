# dtcm-screen: core_session keeps renderer_screen in the data TCM (0021, the
# screen in DTCM). dtcm-none is this file without the keyword: the two builds
# differ in where the screen is, and in their session ids.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries", dtcm: ["renderer_screen"]
state :n, :i64, 1
every_ms 10, :tic

def tic(n)
  n[0] = DoomCore.step(0)
  0
end
