require "bpf"

# P026 E127: cgroup_skb が socket_filter の判定を返す
def p(skb)
  BPF::SF_KEEP
end
BPF.cgroup_skb :p, :ingress
# want: SB028 5:3
