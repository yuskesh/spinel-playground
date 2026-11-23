require "bpf"

# P026 E120: tc の len の書き (読みだけ)
def p(skb)
  skb.len = 5
  BPF::TC_PASS
end
BPF.tcx :p, :egress
# want: SB002 5:3
