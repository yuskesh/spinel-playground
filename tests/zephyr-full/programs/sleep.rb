# sleep and the monotonic clock: Zephyr's nanosleep and clock_gettime
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep 0.1
dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts dt >= 0.1
puts dt < 0.2
