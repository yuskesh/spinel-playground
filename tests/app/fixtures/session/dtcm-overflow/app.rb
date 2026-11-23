# dtcm-overflow: jobs_zonebuf (393,216 B) does not fit the data TCM on either
# core of FRDM-IMXRT1186 (128 KB on the M33, 256 KB on the M7), so step 8
# refuses the build, naming the field and the bytes.
require "spinel/core"
core_session "../../../../../examples/doom/core/entries", dtcm: ["jobs_zonebuf"]
state :n, :i64, 1
every_ms 10, :tic

def tic(n)
  n[0] = DoomCore.step(0)
  0
end
