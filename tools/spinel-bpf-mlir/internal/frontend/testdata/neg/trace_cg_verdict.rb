require "bpf"

# P026 E127: fentry の program の中の cgroup_skb の判定
Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def on_t(ctx)
  Counts.atomic_add(0, 1)
  BPF::CG_DENY
end
BPF.fentry :on_t, "bpf_fentry_test1"
# want: SB028 8:3
