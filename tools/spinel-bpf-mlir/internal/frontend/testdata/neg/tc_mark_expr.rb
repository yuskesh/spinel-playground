require "bpf"

# P026 E120: mark の書きを式の中に (文だけ)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(skb)
  Out.update(0, (skb.mark = 1))
  BPF::TC_PASS
end
BPF.tcx :p, :ingress
# want: SB002 7:18
