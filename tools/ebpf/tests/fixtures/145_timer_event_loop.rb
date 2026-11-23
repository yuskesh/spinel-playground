# E079/E411: `on :timer, every: N.<unit>` — a bpf_timer-backed periodic callback.
#
# This was the E407 NEGATIVE fixture (145_timer_withdrawn) until E411. Same
# source, different verdict, and that is the point: E407 measured this compiling
# with exit 0 into a program whose HANDLER BODY never reached the emitted C (the
# C reactor table had no :timer, and an unknown kind is skipped), while the
# advertised SEC ("syscall") was the same string a silent degradation produces.
# E411 re-ported the timer map, the arm program and the re-arming callback, so
# the golden beside this fixture now contains the body.
#
# The shape is deliberately the one E079 shipped, so the golden can be diffed
# against docs/experiments/results/E079/timer_event_loop.bpf.c — the retired Ruby
# codegen's own output for this source.
@ticks = 0

module Heartbeat
  include BPF::EventLoop

  on :timer, every: 1.seconds do
    @ticks = @ticks + 1
  end
end
