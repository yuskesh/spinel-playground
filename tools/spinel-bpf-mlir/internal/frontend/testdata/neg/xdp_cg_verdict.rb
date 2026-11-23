require "bpf"

# P026 E127: xdp の program が cgroup_skb の判定を返す
def p(ctx)
  BPF::CG_ALLOW
end
BPF.xdp :p
# want: SB028 5:3
