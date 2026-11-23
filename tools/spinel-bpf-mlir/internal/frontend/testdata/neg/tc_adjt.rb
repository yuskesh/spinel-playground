require "bpf"

# P026 E123: tc の context に adjust_tail (xdp だけ)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def p(skb)
  st = skb.adjust_tail(-4)
  Out.update(0, st)
  BPF::TC_PASS
end
BPF.tcx :p, :egress
# want: SB002 7:8
