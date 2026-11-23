require "bpf"

# P026 E127: 向きが String の cgroup_skb
def p(skb)
  BPF::CG_ALLOW
end
BPF.cgroup_skb :p, "ingress"
# want: SB008 7:1
