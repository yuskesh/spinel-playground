require "bpf"

# P026 E127: cgroup_skb が XDP の判定を返す
def p(skb)
  BPF::XDP_PASS
end
BPF.cgroup_skb :p, :egress
# want: SB028 5:3
