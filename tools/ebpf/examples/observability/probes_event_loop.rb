# examples/observability/probes_event_loop.rb
#
# E077: per-target attach kinds in BPF::EventLoop. Same reactor module
# now hosts kprobe and tracepoint handlers via:
#
#   on :kprobe, "<kernel_func>" do ... end
#   on :fentry, "<kernel_func>" do ... end
#   on :fexit,  "<kernel_func>" do ... end
#   on :tracepoint, "<category>", "<event>" do ... end
#
# Each handler is synthesized to the existing flat-prefix form
# (`kprobe__<name>`, `fentry__<name>`, `tracepoint__<cat>__<event>`)
# so the codegen pipeline is untouched. E076's arity-0 forms
# (`on :xdp` etc.) still work and can mix freely in the same module.
#
# Build:
#   spinel-ebpf compile examples/observability/probes_event_loop.rb \
#       -o build/probes_event_loop --build
# Run:
#   ./build/probes_event_loop/probes_event_loop &
#   # Generate kernel activity:
#   ls /etc /tmp >/dev/null   # triggers do_sys_openat2
#   ps >/dev/null              # may trigger context switches
#   # カーネルが保持する map 名は 15 文字までなので、この 2 本は
#   # どれも `probes_event_l_` に見えて名前では区別できない。id で 1 本ずつ引く:
#   bpftool map show | grep probes_event_l_
#   bpftool map dump id <上で出た id>

@open_count   = 0
@switch_count = 0

module KernelProbes
  include BPF::EventLoop

  # E077: kprobe with target name
  on :kprobe, "do_sys_openat2" do
    @open_count = @open_count + 1
  end

  # E077: tracepoint with category + event
  on :tracepoint, "sched", "sched_switch" do
    @switch_count = @switch_count + 1
  end
end

puts "[E077] KernelProbes loaded (kprobe + tracepoint via BPF::EventLoop)"
sleep 3600
