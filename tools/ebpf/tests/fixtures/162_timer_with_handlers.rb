# E411: a timer sharing a module with an ordinary handler.
#
# 145 pins the timer alone (E079's shape, diffable against that Edoc's artifact).
# This one pins the part 145 cannot show: a timer is emitted by a SHORT-CIRCUIT in
# the per-method loop, so it has to leave every other method's inner+wrapper
# untouched and the section order intact. `@opens` is written by the kprobe and
# read by the timer, which is the reactor DSL's whole premise (one module, several
# event sources, shared ivars) and the shape examples/observability's
# full_observability_demo.rb uses.
@opens = 0
@ticks = 0
@last  = 0

module Sampler
  include BPF::EventLoop

  on :kprobe, "do_sys_openat2" do
    @opens = @opens + 1
  end

  # Every 500 ms: publish the count the kprobe has been accumulating and reset it,
  # i.e. the kernel-side "periodic aggregation" E079 existed for.
  on :timer, every: 500.milliseconds do
    @last  = @opens
    @opens = 0
    @ticks = @ticks + 1
  end
end
