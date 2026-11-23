require "bpf"

# P026 E127: 向きの無い cgroup_skb
def p(skb)
  BPF::CG_ALLOW
end
BPF.cgroup_skb :p
# want: SB008 7:1
