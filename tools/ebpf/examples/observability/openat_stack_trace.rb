# examples/observability/openat_stack_trace.rb
#
# E088: capture the kernel call stack at do_sys_openat2 entry, bin by
# stack id (so identical stacks share one slot). Userspace dumps each
# unique stack with kallsyms-symbolized PC list.
#
# Build:
#   bin/spinel-ebpf compile examples/observability/openat_stack_trace.rb \
#                   -o build/stack --build
# Run:
#   ./build/stack/openat_stack_trace &
#   for i in $(seq 1 50); do cat /etc/hostname > /dev/null; done
#
# Inspect:
#   bpftool map dump name bpf_hist_keyed   — count per stack id
#   bpftool map dump name bpf_stack_trace — PC list per stack id

def kprobe__do_sys_openat2(dfd, filename)
  ksid = stack_id
  if ksid >= 0
    # E085: count occurrences per (stack id)
    hist_observe_by(ksid, 1)
  end
end

puts "[E088] openat_stack_trace loaded — exercise then dump bpf_stack_trace (15 chars max)"
sleep 3600
