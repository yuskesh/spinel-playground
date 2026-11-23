require "bpf"

# P026 E127: 知らない向きの cgroup_skb
def p(skb)
  BPF::CG_ALLOW
end
BPF.cgroup_skb :p, :forward
# want: SB008 7:1
