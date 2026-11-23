require "bpf"

# P026 E120: cgroup_skb の context の mark (能力の表に無い)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(skb)
  Out.update(0, skb.mark)
  BPF::CG_ALLOW
end
BPF.cgroup_skb :p, :ingress
# want: SB002 7:17
