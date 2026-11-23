# The M33 companion of decision 0027 beside the RT1186 application on the
# board's Cortex-M7 (tests/app/build.sh 2e): one periodic entry and no
# channel, since the M33 has no console in stage 1.
require "spinel/core"
state :beats, :i32, 1
every_ms 1000, :beat

def beat(beats)
  beats[0] = core_w32_add(beats[0], 1)
  0
end
