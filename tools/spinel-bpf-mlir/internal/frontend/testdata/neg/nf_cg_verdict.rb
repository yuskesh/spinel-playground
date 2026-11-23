require "bpf"

# P026 E128: netfilter が cgroup_skb の判定を返す
def p(ctx)
  BPF::CG_ALLOW
end
BPF.netfilter :p
# want: SB028 5:3
